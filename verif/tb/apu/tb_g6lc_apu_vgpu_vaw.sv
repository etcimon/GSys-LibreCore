// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_vaw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0, cancel = 0;
  apu_vgpu_vik_t vik;
  apu_vgpu_gpk_t gpk;
  apu_vgpu_ols_t ols;
  apu_vgpu_nxc_t nxc;
  apu_vgpu_cwr_t cwr;
  apu_vgpu_cxr_t cxr;
  logic vaw_req = 0, vaw_rdy, vaw_cpl_v, vaw_cpl_r = 0;
  apu_vgpu_vaw_cpl_t vaw_cpl;
  apu_vgpu_vaw_t vaw;
  logic ard_v, ard_rdy, ard_rsp_v = 0, ard_rsp_rdy, ard_rsp_ok = 0;
  logic [63:0] ard_addr, ard_rsp_addr = 0, aseen = 0;
  logic [31:0] ard_len, ard_rsp_len = 0;
  logic [255:0] ard_rsp_data = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wseen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic var_req = 0, var_rdy, var_cpl_v, var_cpl_r = 0;
  apu_vgpu_var_cpl_t var_cpl;
  apu_vgpu_var_t varq;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic vak_req = 0, vak_rdy, vak_cpl_v, vak_cpl_r = 0;
  apu_vgpu_vak_cpl_t vak_cpl, off_cpl;
  apu_vgpu_vak_t vak, off_vak;
  logic off_rdy, off_v;
  logic fail_ard = 0, fail_rd = 0, fail_wr = 0, bad_tail = 0;
  logic a_order = 0, w_order = 0, w_data = 0, rd_order = 0;
  logic [31:0] ack_word = 32'h1;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int naread = 0, nwrite = 0, nread = 0, rd_base = 0;

  assign ard_rdy = ard_v && rst_ni && !ard_rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_vaw #(.Enable(1'b1)) i_vaw (
    .clk_i(clk), .rst_ni, .cancel_i(cancel),
    .vik_i(vik), .gpk_i(gpk), .ols_i(ols), .nxc_i(nxc), .cwr_i(cwr), .cxr_i(cxr),
    .req_valid_i(vaw_req), .req_ready_o(vaw_rdy),
    .cpl_valid_o(vaw_cpl_v), .cpl_ready_i(vaw_cpl_r), .cpl_o(vaw_cpl), .vaw_o(vaw),
    .rd_valid_o(ard_v), .rd_ready_i(ard_rdy), .rd_addr_o(ard_addr), .rd_len_o(ard_len),
    .rd_rsp_valid_i(ard_rsp_v), .rd_rsp_ready_o(ard_rsp_rdy), .rd_rsp_ok_i(ard_rsp_ok),
    .rd_rsp_addr_i(ard_rsp_addr), .rd_rsp_len_i(ard_rsp_len), .rd_rsp_data_i(ard_rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_var #(.Enable(1'b1)) i_var (
    .clk_i(clk), .rst_ni, .vaw_i(vaw), .vik_i(vik), .gpk_i(gpk), .ols_i(ols),
    .req_valid_i(var_req), .req_ready_o(var_rdy),
    .cpl_valid_o(var_cpl_v), .cpl_ready_i(var_cpl_r), .cpl_o(var_cpl), .var_o(varq),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_vak #(.Enable(1'b1)) i_vak (
    .clk_i(clk), .rst_ni, .var_i(varq), .vaw_i(vaw), .vik_i(vik), .gpk_i(gpk),
    .ols_i(ols),
    .req_valid_i(vak_req), .req_ready_o(vak_rdy),
    .cpl_valid_o(vak_cpl_v), .cpl_ready_i(vak_cpl_r), .cpl_o(vak_cpl), .vak_o(vak)
  );
  g6lc_apu_vgpu_vak_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .var_i(varq), .vaw_i(vaw), .vik_i(vik), .gpk_i(gpk),
    .ols_i(ols),
    .req_valid_i(vak_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(vak_cpl_r), .cpl_o(off_cpl), .vak_o(off_vak)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu vaw timeout case=%0d", cases); end

  function automatic logic [255:0] ack_pat(input logic [31:0] word);
    ack_pat = '0;
    ack_pat[255:32] = 224'h1;
    ack_pat[31:0] = word;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      ard_rsp_v <= 1'b0;
      naread <= 0;
      a_order <= 1'b0;
    end else if (ard_rsp_v && ard_rsp_rdy) ard_rsp_v <= 1'b0;
    else if (ard_v && ard_rdy) begin
      if (ard_addr != APU_VGPU_VAW_ADDR || ard_len != 32'd4) a_order <= 1'b1;
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
      if (wr_addr != APU_VGPU_VIW_ADDR || wr_len != 32'd4) w_order <= 1'b1;
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
      want = idx == 0 ? APU_VGPU_VAW_ADDR : APU_VGPU_VIW_ADDR;
      word = idx == 0 ? APU_VGPU_VIW_REASON : APU_VGPU_VAW_CLEAR;
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
    vik = '0;
    vik.valid = 1'b1;
    vik.reason = APU_VGPU_VIW_REASON;
    vik.used_idx = 16'd1;
    gpk = '0;
    gpk.valid = 1'b1;
    gpk.word = APU_VGPU_CLEAR_WORD;
    gpk.first = APU_VGPU_GPW_ADDR;
    gpk.last = APU_VGPU_GPW_TAIL;
    ols = '0;
    ols.valid = 1'b1;
    ols.count = 32'h0;
    ols.capset_id = 32'h0;
    ols.resp = VGPU_RESP_OK_NODATA;
    nxc = '0;
    nxc.valid = 1'b1;
    nxc.head = 16'd0;
    nxc.avail_idx = 16'd1;
    nxc.buf_len = APU_VGPU_SCENE_BYTES;
    nxc.buf_addr = APU_VGPU_EXEC_ADDR;
    nxc.rsp_addr = APU_VGPU_RSP_ADDR;
    cwr = '0;
    cwr.valid = 1'b1;
    cwr.word = APU_VGPU_CLEAR_WORD;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    ack_word = APU_VGPU_VIW_REASON;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_vak == '0 &&
          off_cpl == '0);
  endtask

  task automatic vaw_step(input apu_vgpu_vaw_status_e st, input string name);
    int nr, nw;
    @(negedge clk);
    while (!vaw_rdy) @(negedge clk);
    cases++;
    nr = naread;
    nw = nwrite;
    vaw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vaw_req = 1'b0;
    while (!vaw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vaw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_VAW_OK) begin
      check("acked", vaw.valid && vaw.ack == APU_VGPU_VIW_REASON &&
            vaw.remain == APU_VGPU_VAW_CLEAR && vaw.used_idx == 16'd1);
      check("bus", naread == nr + 1 && nwrite == nw + 1 && !a_order &&
            !w_order && !w_data && aseen == APU_VGPU_VAW_ADDR &&
            wseen == APU_VGPU_VIW_ADDR);
    end else if (name == "bad beat" || name == "config ack" || name == "zero ack") begin
      check("read only", naread == nr + 1 && nwrite == nw && !vaw.valid);
    end else if (name == "bad clear") begin
      check("both beats", naread == nr + 1 && nwrite == nw + 1 && !vaw.valid);
    end else check("no bus", naread == nr && nwrite == nw);
    @(negedge clk);
    check($sformatf("%s held", name), vaw_cpl_v);
    vaw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vaw_cpl_r = 1'b0;
    while (vaw_cpl_v) @(negedge clk);
  endtask

  task automatic var_step(input apu_vgpu_var_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!var_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    var_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    var_req = 1'b0;
    while (!var_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), var_cpl.status == st);
    quiet();
    if (st == APU_VGPU_VAR_OK) begin
      check("readback", varq.valid && varq.ack == vaw.ack &&
            varq.remain == vaw.remain && varq.used_idx == vaw.used_idx &&
            varq.ack != varq.remain);
      check("read count", nread == n0 + 2 && !rd_order &&
            rd_seen0 == APU_VGPU_VAW_ADDR && rd_seen1 == APU_VGPU_VIW_ADDR);
    end else if (name == "bad beat") begin
      check("one beat", nread == n0 + 1 && !varq.valid);
    end else if (name == "bad tail") begin
      check("two beats", nread == n0 + 2 && !varq.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), var_cpl_v);
    var_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    var_cpl_r = 1'b0;
    while (var_cpl_v) @(negedge clk);
  endtask

  task automatic vak_step(input apu_vgpu_vak_status_e st, input string name);
    @(negedge clk);
    while (!vak_rdy) @(negedge clk);
    cases++;
    vak_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vak_req = 1'b0;
    while (!vak_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vak_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), vak_cpl_v);
    vak_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vak_cpl_r = 1'b0;
    while (vak_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    vaw_req = 1'b0;
    var_req = 1'b0;
    vak_req = 1'b0;
    vaw_cpl_r = 1'b0;
    var_cpl_r = 1'b0;
    vak_cpl_r = 1'b0;
    cancel = 1'b0;
    ard_rsp_v = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    vik = '0;
    gpk = '0;
    ols = '0;
    nxc = '0;
    cwr = '0;
    cxr = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          vaw == '0 && varq == '0 && vak == '0);
    check("profiles keep the ack off",
          !ApuOff.VawEn && !ApuOff.VarEn && !ApuOff.VakEn &&
          !ApuP1Transport.VawEn && !ApuP1Transport.VarEn && !ApuP1Transport.VakEn &&
          !ApuHarness.VawEn && !ApuHarness.VarEn && !ApuHarness.VakEn &&
          !ApuSchedBoth.VawEn && !ApuSchedBoth.VarEn && !ApuSchedBoth.VakEn &&
          !ApuBadVirglGrant.VawEn && !ApuBadVirglGrant.VarEn &&
          !ApuBadVirglGrant.VakEn);
    cfg = ApuP1Transport;
    cfg.VawEn = 1'b1;
    cfg.VarEn = 1'b1;
    cfg.VakEn = 1'b1;
    check("ack does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.VawEn = 1'b1;
    cfg.VarEn = 1'b1;
    cfg.VakEn = 1'b1;
    check("ack does not legalize virgl", !apu_cfg_legal(cfg));
    check("ack places",
          APU_VGPU_VAW_ADDR == 64'h8800E510 &&
          APU_VGPU_VAW_CLEAR == 32'h0 &&
          APU_VGPU_VIW_REASON == 32'h1 &&
          APU_VGPU_VAW_ADDR != APU_VGPU_VIW_ADDR &&
          APU_VGPU_VAW_ADDR != APU_VGPU_GCW_IDX &&
          APU_VGPU_VAW_ADDR != 64'h40001000);

    var_step(APU_VGPU_VAR_EMPTY, "read empty");
    vaw_step(APU_VGPU_VAW_EMPTY, "ack empty");
    vak_step(APU_VGPU_VAK_EMPTY, "keep empty");
    good_in();
    gpk = '0;
    vaw_step(APU_VGPU_VAW_EMPTY, "window missing");
    good_in();
    cxr.height = 16'd64;
    vaw_step(APU_VGPU_VAW_FAULT, "bad scissor");
    good_in();
    cancel = 1'b1;
    vaw_step(APU_VGPU_VAW_FAULT, "cancel");
    cancel = 1'b0;
    fail_ard = 1'b1;
    vaw_step(APU_VGPU_VAW_FAULT, "bad beat");
    good_in();
    ack_word = 32'h2;
    vaw_step(APU_VGPU_VAW_FAULT, "config ack");
    good_in();
    ack_word = 32'h0;
    vaw_step(APU_VGPU_VAW_FAULT, "zero ack");
    good_in();
    fail_wr = 1'b1;
    vaw_step(APU_VGPU_VAW_FAULT, "bad clear");
    vaw_step(APU_VGPU_VAW_OK, "ack");
    vaw_step(APU_VGPU_VAW_FAULT, "ack again");
    check("ack stays", vaw.valid && vaw.ack == 32'h1 && vaw.remain == 32'h0);
    fail_rd = 1'b1;
    var_step(APU_VGPU_VAR_FAULT, "bad beat");
    bad_tail = 1'b1;
    var_step(APU_VGPU_VAR_FAULT, "bad tail");
    var_step(APU_VGPU_VAR_OK, "read ack");
    var_step(APU_VGPU_VAR_FAULT, "read ack again");
    check("read stays", varq.ack == 32'h1 && varq.remain == 32'h0 &&
          varq.used_idx == 16'd1);
    gpk.word = 32'h0;
    vak_step(APU_VGPU_VAK_FAULT, "keep bad word");
    check("keep rejected", !vak.valid);
    gpk.word = APU_VGPU_CLEAR_WORD;
    vak_step(APU_VGPU_VAK_OK, "keep ack");
    check("ack kept", vak.valid && vak.ack == 32'h1 && vak.remain == 32'h0 &&
          vak.used_idx == 16'd1);
    vak_step(APU_VGPU_VAK_FAULT, "keep again");
    check("keep stays", vak.ack == vaw.ack && vak.remain == vaw.remain);

    pulse_reset();
    check("reset clears", vaw == '0 && varq == '0 && vak == '0);
    zero_in();
    vaw_step(APU_VGPU_VAW_EMPTY, "after reset");
    var_step(APU_VGPU_VAR_EMPTY, "read after reset");
    vak_step(APU_VGPU_VAK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu vaw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_vaw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
