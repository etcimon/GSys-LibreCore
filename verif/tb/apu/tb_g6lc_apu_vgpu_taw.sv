// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_taw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0, cancel = 0;
  apu_vgpu_tix_t tix;
  logic taw_req = 0, taw_rdy, taw_cpl_v, taw_cpl_r = 0;
  apu_vgpu_taw_cpl_t taw_cpl;
  apu_vgpu_taw_t taw;
  logic ard_v, ard_rdy, ard_rsp_v = 0, ard_rsp_rdy, ard_rsp_ok = 0;
  logic [63:0] ard_addr, ard_rsp_addr = 0, aseen = 0;
  logic [31:0] ard_len, ard_rsp_len = 0;
  logic [255:0] ard_rsp_data = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wseen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic tar_req = 0, tar_rdy, tar_cpl_v, tar_cpl_r = 0;
  apu_vgpu_tar_cpl_t tar_cpl;
  apu_vgpu_tar_t tarq;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic tax_req = 0, tax_rdy, tax_cpl_v, tax_cpl_r = 0;
  apu_vgpu_tax_cpl_t tax_cpl, off_cpl;
  apu_vgpu_tax_t tax, off_tax;
  logic off_rdy, off_v;
  logic fail_ard = 0, fail_rd = 0, fail_wr = 0, bad_tail = 0;
  logic a_order = 0, w_order = 0, w_data = 0, rd_order = 0;
  logic [31:0] ack_word = 32'h1;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int naread = 0, nwrite = 0, nread = 0, rd_base = 0;

  assign ard_rdy = ard_v && rst_ni && !ard_rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_taw #(.Enable(1'b1)) i_taw (
    .clk_i(clk), .rst_ni, .cancel_i(cancel),
    .tix_i(tix),
    .req_valid_i(taw_req), .req_ready_o(taw_rdy),
    .cpl_valid_o(taw_cpl_v), .cpl_ready_i(taw_cpl_r), .cpl_o(taw_cpl), .taw_o(taw),
    .rd_valid_o(ard_v), .rd_ready_i(ard_rdy), .rd_addr_o(ard_addr), .rd_len_o(ard_len),
    .rd_rsp_valid_i(ard_rsp_v), .rd_rsp_ready_o(ard_rsp_rdy), .rd_rsp_ok_i(ard_rsp_ok),
    .rd_rsp_addr_i(ard_rsp_addr), .rd_rsp_len_i(ard_rsp_len), .rd_rsp_data_i(ard_rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_tar #(.Enable(1'b1)) i_tar (
    .clk_i(clk), .rst_ni, .taw_i(taw), .tix_i(tix),
    .req_valid_i(tar_req), .req_ready_o(tar_rdy),
    .cpl_valid_o(tar_cpl_v), .cpl_ready_i(tar_cpl_r), .cpl_o(tar_cpl), .tar_o(tarq),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_tax #(.Enable(1'b1)) i_tax (
    .clk_i(clk), .rst_ni, .tar_i(tarq), .taw_i(taw), .tix_i(tix),
    .req_valid_i(tax_req), .req_ready_o(tax_rdy),
    .cpl_valid_o(tax_cpl_v), .cpl_ready_i(tax_cpl_r), .cpl_o(tax_cpl), .tax_o(tax)
  );
  g6lc_apu_vgpu_tax_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .tar_i(tarq), .taw_i(taw), .tix_i(tix),
    .req_valid_i(tax_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(tax_cpl_r), .cpl_o(off_cpl), .tax_o(off_tax)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu taw timeout case=%0d", cases); end

  function automatic logic [255:0] ack_pat(input logic [31:0] word);
    ack_pat = {224'h0, word};
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      ard_rsp_v <= 1'b0;
      naread <= 0;
      a_order <= 1'b0;
    end else if (ard_rsp_v && ard_rsp_rdy) ard_rsp_v <= 1'b0;
    else if (ard_v && ard_rdy) begin
      if (ard_addr != APU_VGPU_TAW_ADDR || ard_len != 32'd4) a_order <= 1'b1;
      aseen <= ard_addr;
      ard_rsp_addr <= ard_addr;
      ard_rsp_len <= ard_len;
      ard_rsp_data <= ack_pat(ack_word);
      ard_rsp_ok <= !fail_ard;
      fail_ard <= 1'b0;
      naread <= naread + 1;
      ard_rsp_v <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
      w_order <= 1'b0;
      w_data <= 1'b0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      if (wr_addr != APU_VGPU_TIW_ADDR || wr_len != 32'd4) w_order <= 1'b1;
      if (wr_data != {224'h0, APU_VGPU_VAW_CLEAR}) w_data <= 1'b1;
      wseen <= wr_addr;
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
      int idx;
      logic [63:0] want;
      logic [31:0] word;
      idx = nread - rd_base;
      want = idx == 0 ? APU_VGPU_TAW_ADDR : APU_VGPU_TIW_ADDR;
      word = idx == 0 ? APU_VGPU_TIW_REASON : APU_VGPU_VAW_CLEAR;
      if (idx == 1 && bad_tail) word = 32'h1;
      if (rd_addr != want || rd_len != 32'd4) rd_order <= 1'b1;
      if (idx == 0) rd_seen0 <= rd_addr;
      else rd_seen1 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= ack_pat(word);
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      if (idx == 1) bad_tail <= 1'b0;
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
    tix = '0;
    tix.valid = 1'b1;
    tix.reason = APU_VGPU_TIW_REASON;
    tix.used_idx = APU_VGPU_TUW_IDXV;
    tix.addr = APU_VGPU_TIW_ADDR;
    ack_word = APU_VGPU_TIW_REASON;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_tax == '0 &&
          off_cpl == '0);
  endtask

  task automatic taw_step(input apu_vgpu_taw_status_e st, input string name);
    int nr, nw;
    @(negedge clk);
    while (!taw_rdy) @(negedge clk);
    cases++;
    nr = naread;
    nw = nwrite;
    taw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    taw_req = 1'b0;
    while (!taw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), taw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_TAW_OK) begin
      check("acked", taw.valid && taw.ack == APU_VGPU_TIW_REASON &&
            taw.remain == APU_VGPU_VAW_CLEAR &&
            taw.used_idx == APU_VGPU_TUW_IDXV &&
            taw.ack_addr == APU_VGPU_TAW_ADDR &&
            taw.status_addr == APU_VGPU_TIW_ADDR &&
            taw.ack_addr != APU_VGPU_VAW_ADDR &&
            taw.status_addr != APU_VGPU_VIW_ADDR);
      check("bus", naread == nr + 1 && nwrite == nw + 1 && !a_order &&
            !w_order && !w_data && aseen == APU_VGPU_TAW_ADDR &&
            wseen == APU_VGPU_TIW_ADDR);
    end else if (name == "bad beat" || name == "config ack" || name == "zero ack") begin
      check("read only", naread == nr + 1 && nwrite == nw && !taw.valid);
    end else if (name == "bad clear") begin
      check("both beats", naread == nr + 1 && nwrite == nw + 1 && !taw.valid);
    end else check("no bus", naread == nr && nwrite == nw);
    @(negedge clk);
    check($sformatf("%s held", name), taw_cpl_v);
    taw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    taw_cpl_r = 1'b0;
    while (taw_cpl_v) @(negedge clk);
  endtask

  task automatic tar_step(input apu_vgpu_tar_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!tar_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    tar_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tar_req = 1'b0;
    while (!tar_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tar_cpl.status == st);
    quiet();
    if (st == APU_VGPU_TAR_OK) begin
      check("readback", tarq.valid && tarq.ack == taw.ack &&
            tarq.remain == taw.remain && tarq.used_idx == taw.used_idx &&
            tarq.ack != tarq.remain &&
            tarq.ack_addr == APU_VGPU_TAW_ADDR &&
            tarq.status_addr == APU_VGPU_TIW_ADDR);
      check("read count", nread == n0 + 2 && !rd_order &&
            rd_seen0 == APU_VGPU_TAW_ADDR && rd_seen1 == APU_VGPU_TIW_ADDR);
    end else if (name == "bad beat") begin
      check("one beat", nread == n0 + 1 && !tarq.valid);
    end else if (name == "bad tail") begin
      check("two beats", nread == n0 + 2 && !tarq.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), tar_cpl_v);
    tar_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tar_cpl_r = 1'b0;
    while (tar_cpl_v) @(negedge clk);
  endtask

  task automatic tax_step(input apu_vgpu_tax_status_e st, input string name);
    @(negedge clk);
    while (!tax_rdy) @(negedge clk);
    cases++;
    tax_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tax_req = 1'b0;
    while (!tax_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tax_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), tax_cpl_v);
    tax_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tax_cpl_r = 1'b0;
    while (tax_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    taw_req = 1'b0;
    tar_req = 1'b0;
    tax_req = 1'b0;
    taw_cpl_r = 1'b0;
    tar_cpl_r = 1'b0;
    tax_cpl_r = 1'b0;
    cancel = 1'b0;
    ard_rsp_v = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    tix = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          taw == '0 && tarq == '0 && tax == '0);
    check("profiles keep the ack off",
          !ApuOff.TawEn && !ApuOff.TarEn && !ApuOff.TaxEn &&
          !ApuP1Transport.TawEn && !ApuP1Transport.TarEn && !ApuP1Transport.TaxEn &&
          !ApuHarness.TawEn && !ApuHarness.TarEn && !ApuHarness.TaxEn &&
          !ApuSchedBoth.TawEn && !ApuSchedBoth.TarEn && !ApuSchedBoth.TaxEn &&
          !ApuBadVirglGrant.TawEn && !ApuBadVirglGrant.TarEn &&
          !ApuBadVirglGrant.TaxEn);
    cfg = ApuP1Transport;
    cfg.TawEn = 1'b1;
    cfg.TarEn = 1'b1;
    cfg.TaxEn = 1'b1;
    check("ack does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.TawEn = 1'b1;
    cfg.TarEn = 1'b1;
    cfg.TaxEn = 1'b1;
    check("ack does not legalize virgl", !apu_cfg_legal(cfg));
    check("ack places",
          APU_VGPU_TAW_ADDR == 64'h880C0010 &&
          APU_VGPU_VAW_CLEAR == 32'h0 &&
          APU_VGPU_TIW_REASON == 32'h1 &&
          APU_VGPU_TAW_ADDR != APU_VGPU_VAW_ADDR &&
          APU_VGPU_TAW_ADDR != APU_VGPU_TIW_ADDR &&
          APU_VGPU_TAW_ADDR != APU_VGPU_VIW_ADDR &&
          APU_VGPU_TAW_ADDR != 64'h40001000);

    tar_step(APU_VGPU_TAR_EMPTY, "read empty");
    taw_step(APU_VGPU_TAW_EMPTY, "ack empty");
    tax_step(APU_VGPU_TAX_EMPTY, "keep empty");
    good_in();
    cancel = 1'b1;
    taw_step(APU_VGPU_TAW_FAULT, "cancel");
    cancel = 1'b0;
    tix.addr = APU_VGPU_VIW_ADDR;
    taw_step(APU_VGPU_TAW_FAULT, "scene status");
    good_in();
    tix.used_idx = 16'd1;
    taw_step(APU_VGPU_TAW_FAULT, "scene index");
    good_in();
    fail_ard = 1'b1;
    taw_step(APU_VGPU_TAW_FAULT, "bad beat");
    good_in();
    ack_word = 32'h2;
    taw_step(APU_VGPU_TAW_FAULT, "config ack");
    good_in();
    ack_word = 32'h0;
    taw_step(APU_VGPU_TAW_FAULT, "zero ack");
    good_in();
    fail_wr = 1'b1;
    taw_step(APU_VGPU_TAW_FAULT, "bad clear");
    taw_step(APU_VGPU_TAW_OK, "ack");
    taw_step(APU_VGPU_TAW_FAULT, "ack again");
    check("ack stays", taw.valid && taw.ack == 32'h1 && taw.remain == 32'h0 &&
          taw.used_idx == 16'd2);
    fail_rd = 1'b1;
    tar_step(APU_VGPU_TAR_FAULT, "bad beat");
    bad_tail = 1'b1;
    tar_step(APU_VGPU_TAR_FAULT, "bad tail");
    tar_step(APU_VGPU_TAR_OK, "read ack");
    tar_step(APU_VGPU_TAR_FAULT, "read ack again");
    check("read stays", tarq.ack == 32'h1 && tarq.remain == 32'h0 &&
          tarq.used_idx == 16'd2);
    tix.used_idx = 16'd1;
    tax_step(APU_VGPU_TAX_FAULT, "keep bad index");
    check("keep rejected", !tax.valid);
    tix.used_idx = APU_VGPU_TUW_IDXV;
    tax_step(APU_VGPU_TAX_OK, "keep ack");
    check("ack kept", tax.valid && tax.ack == 32'h1 && tax.remain == 32'h0 &&
          tax.used_idx == 16'd2);
    tax_step(APU_VGPU_TAX_FAULT, "keep again");
    check("keep stays", tax.ack == taw.ack && tax.remain == taw.remain);

    pulse_reset();
    check("reset clears", taw == '0 && tarq == '0 && tax == '0);
    zero_in();
    taw_step(APU_VGPU_TAW_EMPTY, "after reset");
    tar_step(APU_VGPU_TAR_EMPTY, "read after reset");
    tax_step(APU_VGPU_TAX_EMPTY, "keep after reset");
    good_in();
    taw_step(APU_VGPU_TAW_OK, "ack after reset");

    if (errors != 0) $fatal(1, "APU vgpu taw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_taw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
