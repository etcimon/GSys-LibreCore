// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_slw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_sox_t sox;
  logic slw_req = 0, slw_rdy, slw_cpl_v, slw_cpl_r = 0;
  apu_vgpu_slw_cpl_t slw_cpl;
  apu_vgpu_slw_t slw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen0 = 0, wr_seen1 = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic sll_req = 0, sll_rdy, sll_cpl_v, sll_cpl_r = 0;
  apu_vgpu_sll_cpl_t sll_cpl;
  apu_vgpu_sll_t sll;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic slx_req = 0, slx_rdy, slx_cpl_v, slx_cpl_r = 0;
  apu_vgpu_slx_cpl_t slx_cpl, off_cpl;
  apu_vgpu_slx_t slx, off_slx;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_idx = 0, fail_rd = 0, xfer_id = 0, xfer_idx = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored0 = 0, stored1 = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int nwrite = 0, wr_base = 0, nread = 0, rd_base = 0;

  localparam logic [255:0] ElemBeat = {192'h0, VGPU_RESP_HDR_BYTES, APU_VGPU_QSU_ID};
  localparam logic [255:0] IdxBeat  = {224'h0, APU_VGPU_QSU_IDXV, 16'd0};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_slw #(.Enable(1'b1)) i_slw (
    .clk_i(clk), .rst_ni, .sox_i(sox),
    .req_valid_i(slw_req), .req_ready_o(slw_rdy),
    .cpl_valid_o(slw_cpl_v), .cpl_ready_i(slw_cpl_r), .cpl_o(slw_cpl), .slw_o(slw),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_sll #(.Enable(1'b1)) i_sll (
    .clk_i(clk), .rst_ni, .slw_i(slw), .sox_i(sox),
    .req_valid_i(sll_req), .req_ready_o(sll_rdy),
    .cpl_valid_o(sll_cpl_v), .cpl_ready_i(sll_cpl_r), .cpl_o(sll_cpl), .sll_o(sll),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_slx #(.Enable(1'b1)) i_slx (
    .clk_i(clk), .rst_ni, .sll_i(sll), .slw_i(slw), .sox_i(sox),
    .req_valid_i(slx_req), .req_ready_o(slx_rdy),
    .cpl_valid_o(slx_cpl_v), .cpl_ready_i(slx_cpl_r), .cpl_o(slx_cpl), .slx_o(slx)
  );
  g6lc_apu_vgpu_slx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .sll_i(sll), .slw_i(slw), .sox_i(sox),
    .req_valid_i(slx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(slx_cpl_r), .cpl_o(off_cpl), .slx_o(off_slx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu slw timeout case=%0d", cases); end

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
      want = idx == 0 ? APU_VGPU_QSU_ELEM : APU_VGPU_QSU_IDX;
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
      want = idx == 0 ? APU_VGPU_QSU_ELEM : APU_VGPU_QSU_IDX;
      rlen = idx == 0 ? 32'd8 : 32'd4;
      beat = idx == 0 ? stored0 : stored1;
      if (idx == 0 && xfer_id) beat[31:0] = APU_VGPU_TUW_ID;
      if (idx == 1 && xfer_idx) beat[31:16] = APU_VGPU_TUW_IDXV;
      if (rd_addr != want || rd_len != rlen) rd_order <= 1'b1;
      if (idx == 0) rd_seen0 <= rd_addr;
      rd_seen1 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      if (idx == 0) xfer_id <= 1'b0;
      if (idx == 1) xfer_idx <= 1'b0;
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
    sox = '0;
    sox.valid = 1'b1;
    sox.fence = APU_VGPU_SCENE_FENCE;
    sox.resp = VGPU_RESP_OK_NODATA;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_slx == '0 &&
          off_cpl == '0);
  endtask

  task automatic slw_step(input apu_vgpu_slw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!slw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    wr_base = nwrite;
    slw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    slw_req = 1'b0;
    while (!slw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), slw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SLW_OK) begin
      check("used", slw.valid && slw.elem_id == APU_VGPU_QSU_ID &&
            slw.elem_id != APU_VGPU_TUW_ID && slw.elem_len == VGPU_RESP_HDR_BYTES &&
            slw.used_idx == APU_VGPU_QSU_IDXV && slw.used_idx != APU_VGPU_TUW_IDXV &&
            slw.elem_addr == APU_VGPU_QSU_ELEM &&
            slw.elem_addr != APU_VGPU_TUW_ELEM &&
            slw.idx_addr == APU_VGPU_QSU_IDX);
      check("two writes", nwrite == n0 + 2 && !order_bad && !data_bad &&
            wr_seen0 == APU_VGPU_QSU_ELEM && wr_seen1 == APU_VGPU_QSU_IDX);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !slw.valid);
    end else if (name == "bad index write") begin
      check("two writes failed", nwrite == n0 + 2 && !slw.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), slw_cpl_v);
    slw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    slw_cpl_r = 1'b0;
    while (slw_cpl_v) @(negedge clk);
  endtask

  task automatic sll_step(input apu_vgpu_sll_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!sll_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    sll_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sll_req = 1'b0;
    while (!sll_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sll_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SLL_OK) begin
      check("echo", sll.valid && sll.elem_id == APU_VGPU_QSU_ID &&
            sll.used_idx == APU_VGPU_QSU_IDXV &&
            sll.elem_addr == APU_VGPU_QSU_ELEM);
      check("two reads", nread == n0 + 2 && !rd_order &&
            rd_seen0 == APU_VGPU_QSU_ELEM && rd_seen1 == APU_VGPU_QSU_IDX);
    end else if (name == "bad read" || name == "xfer id") begin
      check("one read failed", nread == n0 + 1 && !sll.valid);
    end else if (name == "xfer idx") begin
      check("two reads failed", nread == n0 + 2 && !sll.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), sll_cpl_v);
    sll_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sll_cpl_r = 1'b0;
    while (sll_cpl_v) @(negedge clk);
  endtask

  task automatic slx_step(input apu_vgpu_slx_status_e st, input string name);
    @(negedge clk);
    while (!slx_rdy) @(negedge clk);
    cases++;
    slx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    slx_req = 1'b0;
    while (!slx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), slx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), slx_cpl_v);
    slx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    slx_cpl_r = 1'b0;
    while (slx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    slw_req = 1'b0;
    sll_req = 1'b0;
    slx_req = 1'b0;
    slw_cpl_r = 1'b0;
    sll_cpl_r = 1'b0;
    slx_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    sox = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          slw == '0 && sll == '0 && slx == '0);
    check("profiles keep the used ring off",
          !ApuOff.SlwEn && !ApuOff.SllEn && !ApuOff.SlxEn &&
          !ApuP1Transport.SlwEn && !ApuP1Transport.SllEn &&
          !ApuP1Transport.SlxEn &&
          !ApuHarness.SlwEn && !ApuHarness.SllEn && !ApuHarness.SlxEn &&
          !ApuSchedBoth.SlwEn && !ApuSchedBoth.SllEn && !ApuSchedBoth.SlxEn &&
          !ApuBadVirglGrant.SlwEn && !ApuBadVirglGrant.SllEn &&
          !ApuBadVirglGrant.SlxEn);
    cfg = ApuP1Transport;
    cfg.SlwEn = 1'b1;
    cfg.SllEn = 1'b1;
    cfg.SlxEn = 1'b1;
    check("used ring does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.SlwEn = 1'b1;
    cfg.SllEn = 1'b1;
    cfg.SlxEn = 1'b1;
    check("used ring does not legalize virgl", !apu_cfg_legal(cfg));
    check("known used",
          APU_VGPU_QSU_ELEM != APU_VGPU_TUW_ELEM &&
          APU_VGPU_QSU_IDX != APU_VGPU_TUW_IDX &&
          APU_VGPU_QSU_IDX == APU_VGPU_GCW_IDX &&
          APU_VGPU_QSU_ID != APU_VGPU_TUW_ID &&
          APU_VGPU_QSU_IDXV != APU_VGPU_TUW_IDXV);

    slw_step(APU_VGPU_SLW_EMPTY, "write empty");
    sll_step(APU_VGPU_SLL_EMPTY, "read empty");
    slx_step(APU_VGPU_SLX_EMPTY, "index empty");
    good_in();
    sox.fence = APU_VGPU_RFW_FENCE;
    slw_step(APU_VGPU_SLW_FAULT, "xfer fence");
    good_in();
    fail_wr = 1'b1;
    slw_step(APU_VGPU_SLW_FAULT, "bad write");
    fail_idx = 1'b1;
    slw_step(APU_VGPU_SLW_FAULT, "bad index write");
    slw_step(APU_VGPU_SLW_OK, "used element");
    slw_step(APU_VGPU_SLW_FAULT, "write again");
    fail_rd = 1'b1;
    sll_step(APU_VGPU_SLL_FAULT, "bad read");
    xfer_id = 1'b1;
    sll_step(APU_VGPU_SLL_FAULT, "xfer id");
    xfer_idx = 1'b1;
    sll_step(APU_VGPU_SLL_FAULT, "xfer idx");
    sll_step(APU_VGPU_SLL_OK, "echo used");
    sll_step(APU_VGPU_SLL_FAULT, "read again");
    sox.fence = APU_VGPU_RFW_FENCE;
    slx_step(APU_VGPU_SLX_FAULT, "check xfer fence");
    check("check rejected", !slx.valid);
    good_in();
    slx_step(APU_VGPU_SLX_OK, "index one");
    check("index one", slx.valid && slx.used_idx == 16'd1 &&
          slx.used_idx != 16'd2 && slx.elem_id == 32'd0);
    slx_step(APU_VGPU_SLX_FAULT, "index again");
    check("index stays", slx.used_idx == APU_VGPU_QSU_IDXV);

    pulse_reset();
    check("reset clears", slw == '0 && sll == '0 && slx == '0);
    sox = '0;
    slw_step(APU_VGPU_SLW_EMPTY, "after reset");
    good_in();
    slw_step(APU_VGPU_SLW_OK, "write after reset");

    if (errors != 0) $fatal(1, "APU vgpu slw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_slw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
