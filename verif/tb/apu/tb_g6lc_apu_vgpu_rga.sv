// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rga;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0, cancel = 0;
  apu_vgpu_rix_t rix;
  logic rga_req = 0, rga_rdy, rga_cpl_v, rga_cpl_r = 0;
  apu_vgpu_rga_cpl_t rga_cpl;
  apu_vgpu_rga_t rga;
  logic ard_v, ard_rdy, ard_rsp_v = 0, ard_rsp_rdy, ard_rsp_ok = 0;
  logic [63:0] ard_addr, ard_rsp_addr = 0, aseen = 0;
  logic [31:0] ard_len, ard_rsp_len = 0;
  logic [255:0] ard_rsp_data = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wseen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic rgk_req = 0, rgk_rdy, rgk_cpl_v, rgk_cpl_r = 0;
  apu_vgpu_rgk_cpl_t rgk_cpl;
  apu_vgpu_rgk_t rgkq;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic rgx_req = 0, rgx_rdy, rgx_cpl_v, rgx_cpl_r = 0;
  apu_vgpu_rgx_cpl_t rgx_cpl, off_cpl;
  apu_vgpu_rgx_t rgx, off_rgx;
  logic off_rdy, off_v;
  logic fail_ard = 0, fail_rd = 0, fail_wr = 0, bad_tail = 0;
  logic a_order = 0, w_order = 0, w_data = 0, rd_order = 0;
  logic [31:0] ack_word = 32'h1;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int naread = 0, nwrite = 0, nread = 0, rd_base = 0;

  assign ard_rdy = ard_v && rst_ni && !ard_rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_rga #(.Enable(1'b1)) i_rga (
    .clk_i(clk), .rst_ni, .cancel_i(cancel),
    .rix_i(rix),
    .req_valid_i(rga_req), .req_ready_o(rga_rdy),
    .cpl_valid_o(rga_cpl_v), .cpl_ready_i(rga_cpl_r), .cpl_o(rga_cpl), .rga_o(rga),
    .rd_valid_o(ard_v), .rd_ready_i(ard_rdy), .rd_addr_o(ard_addr), .rd_len_o(ard_len),
    .rd_rsp_valid_i(ard_rsp_v), .rd_rsp_ready_o(ard_rsp_rdy), .rd_rsp_ok_i(ard_rsp_ok),
    .rd_rsp_addr_i(ard_rsp_addr), .rd_rsp_len_i(ard_rsp_len), .rd_rsp_data_i(ard_rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_rgk #(.Enable(1'b1)) i_rgk (
    .clk_i(clk), .rst_ni, .rga_i(rga), .rix_i(rix),
    .req_valid_i(rgk_req), .req_ready_o(rgk_rdy),
    .cpl_valid_o(rgk_cpl_v), .cpl_ready_i(rgk_cpl_r), .cpl_o(rgk_cpl), .rgk_o(rgkq),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rgx #(.Enable(1'b1)) i_rgx (
    .clk_i(clk), .rst_ni, .rgk_i(rgkq), .rga_i(rga), .rix_i(rix),
    .req_valid_i(rgx_req), .req_ready_o(rgx_rdy),
    .cpl_valid_o(rgx_cpl_v), .cpl_ready_i(rgx_cpl_r), .cpl_o(rgx_cpl), .rgx_o(rgx)
  );
  g6lc_apu_vgpu_rgx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rgk_i(rgkq), .rga_i(rga), .rix_i(rix),
    .req_valid_i(rgx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rgx_cpl_r), .cpl_o(off_cpl), .rgx_o(off_rgx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rga timeout case=%0d", cases); end

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
    rix = '0;
    rix.valid = 1'b1;
    rix.reason = APU_VGPU_TIW_REASON;
    rix.used_idx = APU_VGPU_TUW_IDXV;
    rix.addr = APU_VGPU_TIW_ADDR;
    ack_word = APU_VGPU_TIW_REASON;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rgx == '0 &&
          off_cpl == '0);
  endtask

  task automatic rga_step(input apu_vgpu_rga_status_e st, input string name);
    int nr, nw;
    @(negedge clk);
    while (!rga_rdy) @(negedge clk);
    cases++;
    nr = naread;
    nw = nwrite;
    rga_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rga_req = 1'b0;
    while (!rga_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rga_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RGA_OK) begin
      check("acked", rga.valid && rga.ack == APU_VGPU_TIW_REASON &&
            rga.remain == APU_VGPU_VAW_CLEAR &&
            rga.used_idx == APU_VGPU_TUW_IDXV &&
            rga.ack_addr == APU_VGPU_TAW_ADDR &&
            rga.status_addr == APU_VGPU_TIW_ADDR &&
            rga.ack_addr != APU_VGPU_VAW_ADDR &&
            rga.status_addr != APU_VGPU_VIW_ADDR);
      check("bus", naread == nr + 1 && nwrite == nw + 1 && !a_order &&
            !w_order && !w_data && aseen == APU_VGPU_TAW_ADDR &&
            wseen == APU_VGPU_TIW_ADDR);
    end else if (name == "bad beat" || name == "config ack" || name == "zero ack") begin
      check("read only", naread == nr + 1 && nwrite == nw && !rga.valid);
    end else if (name == "bad clear") begin
      check("both beats", naread == nr + 1 && nwrite == nw + 1 && !rga.valid);
    end else check("no bus", naread == nr && nwrite == nw);
    @(negedge clk);
    check($sformatf("%s held", name), rga_cpl_v);
    rga_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rga_cpl_r = 1'b0;
    while (rga_cpl_v) @(negedge clk);
  endtask

  task automatic rgk_step(input apu_vgpu_rgk_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rgk_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    rgk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rgk_req = 1'b0;
    while (!rgk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rgk_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RGK_OK) begin
      check("readback", rgkq.valid && rgkq.ack == rga.ack &&
            rgkq.remain == rga.remain && rgkq.used_idx == rga.used_idx &&
            rgkq.ack != rgkq.remain &&
            rgkq.ack_addr == APU_VGPU_TAW_ADDR &&
            rgkq.status_addr == APU_VGPU_TIW_ADDR);
      check("read count", nread == n0 + 2 && !rd_order &&
            rd_seen0 == APU_VGPU_TAW_ADDR && rd_seen1 == APU_VGPU_TIW_ADDR);
    end else if (name == "bad beat") begin
      check("one beat", nread == n0 + 1 && !rgkq.valid);
    end else if (name == "bad tail") begin
      check("two beats", nread == n0 + 2 && !rgkq.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rgk_cpl_v);
    rgk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rgk_cpl_r = 1'b0;
    while (rgk_cpl_v) @(negedge clk);
  endtask

  task automatic rgx_step(input apu_vgpu_rgx_status_e st, input string name);
    @(negedge clk);
    while (!rgx_rdy) @(negedge clk);
    cases++;
    rgx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rgx_req = 1'b0;
    while (!rgx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rgx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rgx_cpl_v);
    rgx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rgx_cpl_r = 1'b0;
    while (rgx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rga_req = 1'b0;
    rgk_req = 1'b0;
    rgx_req = 1'b0;
    rga_cpl_r = 1'b0;
    rgk_cpl_r = 1'b0;
    rgx_cpl_r = 1'b0;
    cancel = 1'b0;
    ard_rsp_v = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    rix = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rga == '0 && rgkq == '0 && rgx == '0);
    check("profiles keep the ack off",
          !ApuOff.RgaEn && !ApuOff.RgkEn && !ApuOff.RgxEn &&
          !ApuP1Transport.RgaEn && !ApuP1Transport.RgkEn && !ApuP1Transport.RgxEn &&
          !ApuHarness.RgaEn && !ApuHarness.RgkEn && !ApuHarness.RgxEn &&
          !ApuSchedBoth.RgaEn && !ApuSchedBoth.RgkEn && !ApuSchedBoth.RgxEn &&
          !ApuBadVirglGrant.RgaEn && !ApuBadVirglGrant.RgkEn &&
          !ApuBadVirglGrant.RgxEn);
    cfg = ApuP1Transport;
    cfg.RgaEn = 1'b1;
    cfg.RgkEn = 1'b1;
    cfg.RgxEn = 1'b1;
    check("ack does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RgaEn = 1'b1;
    cfg.RgkEn = 1'b1;
    cfg.RgxEn = 1'b1;
    check("ack does not legalize virgl", !apu_cfg_legal(cfg));
    check("ack places",
          APU_VGPU_TAW_ADDR == 64'h880C0010 &&
          APU_VGPU_VAW_CLEAR == 32'h0 &&
          APU_VGPU_TIW_REASON == 32'h1 &&
          APU_VGPU_TAW_ADDR != APU_VGPU_VAW_ADDR &&
          APU_VGPU_TAW_ADDR != APU_VGPU_TIW_ADDR &&
          APU_VGPU_TAW_ADDR != APU_VGPU_VIW_ADDR &&
          APU_VGPU_TAW_ADDR != 64'h40001000);

    rgk_step(APU_VGPU_RGK_EMPTY, "read empty");
    rga_step(APU_VGPU_RGA_EMPTY, "ack empty");
    rgx_step(APU_VGPU_RGX_EMPTY, "keep empty");
    good_in();
    cancel = 1'b1;
    rga_step(APU_VGPU_RGA_FAULT, "cancel");
    cancel = 1'b0;
    rix.addr = APU_VGPU_VIW_ADDR;
    rga_step(APU_VGPU_RGA_FAULT, "scene status");
    good_in();
    rix.used_idx = 16'd1;
    rga_step(APU_VGPU_RGA_FAULT, "scene index");
    good_in();
    fail_ard = 1'b1;
    rga_step(APU_VGPU_RGA_FAULT, "bad beat");
    good_in();
    ack_word = 32'h2;
    rga_step(APU_VGPU_RGA_FAULT, "config ack");
    good_in();
    ack_word = 32'h0;
    rga_step(APU_VGPU_RGA_FAULT, "zero ack");
    good_in();
    fail_wr = 1'b1;
    rga_step(APU_VGPU_RGA_FAULT, "bad clear");
    rga_step(APU_VGPU_RGA_OK, "ack");
    rga_step(APU_VGPU_RGA_FAULT, "ack again");
    check("ack stays", rga.valid && rga.ack == 32'h1 && rga.remain == 32'h0 &&
          rga.used_idx == 16'd2);
    fail_rd = 1'b1;
    rgk_step(APU_VGPU_RGK_FAULT, "bad beat");
    bad_tail = 1'b1;
    rgk_step(APU_VGPU_RGK_FAULT, "bad tail");
    rgk_step(APU_VGPU_RGK_OK, "read ack");
    rgk_step(APU_VGPU_RGK_FAULT, "read ack again");
    check("read stays", rgkq.ack == 32'h1 && rgkq.remain == 32'h0 &&
          rgkq.used_idx == 16'd2);
    rix.used_idx = 16'd1;
    rgx_step(APU_VGPU_RGX_FAULT, "keep bad index");
    check("keep rejected", !rgx.valid);
    rix.used_idx = APU_VGPU_TUW_IDXV;
    rgx_step(APU_VGPU_RGX_OK, "keep ack");
    check("ack kept", rgx.valid && rgx.ack == 32'h1 && rgx.remain == 32'h0 &&
          rgx.used_idx == 16'd2);
    rgx_step(APU_VGPU_RGX_FAULT, "keep again");
    check("keep stays", rgx.ack == rga.ack && rgx.remain == rga.remain);

    pulse_reset();
    check("reset clears", rga == '0 && rgkq == '0 && rgx == '0);
    zero_in();
    rga_step(APU_VGPU_RGA_EMPTY, "after reset");
    rgk_step(APU_VGPU_RGK_EMPTY, "read after reset");
    rgx_step(APU_VGPU_RGX_EMPTY, "keep after reset");
    good_in();
    rga_step(APU_VGPU_RGA_OK, "ack after reset");

    if (errors != 0) $fatal(1, "APU vgpu rga errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rga cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
