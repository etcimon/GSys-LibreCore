// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rpw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_cox_t cox;
  apu_vgpu_csw_t csw;
  apu_vgpu_cxr_t cxr;
  logic rpw_req = 0, rpw_rdy, rpw_cpl_v, rpw_cpl_r = 0;
  apu_vgpu_rpw_cpl_t rpw_cpl;
  apu_vgpu_rpw_t rpw;
  logic srd_v, srd_rdy, srd_rsp_v = 0, srd_rsp_rdy, srd_rsp_ok = 0;
  logic [63:0] srd_addr, srd_rsp_addr = 0, sseen = 0;
  logic [31:0] srd_len, srd_rsp_len = 0;
  logic [255:0] srd_rsp_data = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wseen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic rpr_req = 0, rpr_rdy, rpr_cpl_v, rpr_cpl_r = 0;
  apu_vgpu_rpr_cpl_t rpr_cpl;
  apu_vgpu_rpr_t rpr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic [7:0] b0 = 0;
  logic rpx_req = 0, rpx_rdy, rpx_cpl_v, rpx_cpl_r = 0;
  apu_vgpu_rpx_cpl_t rpx_cpl, off_cpl;
  apu_vgpu_rpx_t rpx, off_rpx;
  logic off_rdy, off_v;
  logic fail_s = 0, fail_w = 0, fail_d = 0, bad_src = 0;
  logic swap_lanes = 0, clear_lane = 0;
  logic s_order = 0, w_order = 0, w_data = 0, d_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int ns = 0, nw = 0, nd = 0, sbase = 0, wbase = 0, dbase = 0;

  localparam logic [31:0] Origin = 32'hA500_0000;
  localparam logic [31:0] Neighbor = 32'hD200_8000;
  localparam logic [31:0] Fill = 32'h1111_1111;
  localparam logic [255:0] Beat0 = {192'b0, Neighbor, Origin};
  localparam logic [255:0] FillBeat = {8{Fill}};

  assign srd_rdy = srd_v && rst_ni && !srd_rsp_v;
  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_rpw #(.Enable(1'b1)) i_rpw (
    .clk_i(clk), .rst_ni, .cox_i(cox), .csw_i(csw), .cxr_i(cxr),
    .req_valid_i(rpw_req), .req_ready_o(rpw_rdy),
    .cpl_valid_o(rpw_cpl_v), .cpl_ready_i(rpw_cpl_r), .cpl_o(rpw_cpl), .rpw_o(rpw),
    .rd_valid_o(srd_v), .rd_ready_i(srd_rdy), .rd_addr_o(srd_addr), .rd_len_o(srd_len),
    .rd_rsp_valid_i(srd_rsp_v), .rd_rsp_ready_o(srd_rsp_rdy), .rd_rsp_ok_i(srd_rsp_ok),
    .rd_rsp_addr_i(srd_rsp_addr), .rd_rsp_len_i(srd_rsp_len), .rd_rsp_data_i(srd_rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_rpr #(.Enable(1'b1)) i_rpr (
    .clk_i(clk), .rst_ni, .rpw_i(rpw), .cox_i(cox), .cxr_i(cxr),
    .req_valid_i(rpr_req), .req_ready_o(rpr_rdy),
    .cpl_valid_o(rpr_cpl_v), .cpl_ready_i(rpr_cpl_r), .cpl_o(rpr_cpl), .rpr_o(rpr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rpx #(.Enable(1'b1)) i_rpx (
    .clk_i(clk), .rst_ni, .rpr_i(rpr), .b0_i(b0),
    .req_valid_i(rpx_req), .req_ready_o(rpx_rdy),
    .cpl_valid_o(rpx_cpl_v), .cpl_ready_i(rpx_cpl_r), .cpl_o(rpx_cpl), .rpx_o(rpx)
  );
  g6lc_apu_vgpu_rpx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rpr_i(rpr), .b0_i(b0),
    .req_valid_i(rpx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rpx_cpl_r), .cpl_o(off_cpl), .rpx_o(off_rpx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rpw timeout case=%0d s=%0d", cases, ns); end

  function automatic logic [255:0] src_beat(input int idx);
    if (idx == 0) src_beat = Beat0;
    else src_beat = FillBeat;
  endfunction
  function automatic logic [63:0] at_src(input int idx);
    at_src = APU_VGPU_CSW_DST + (64'(idx) << 5);
  endfunction
  function automatic logic [63:0] at_dst(input int idx);
    at_dst = APU_VGPU_RPW_DST + (64'(idx) << 5);
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      srd_rsp_v <= 1'b0;
      ns <= 0;
      s_order <= 1'b0;
    end else if (srd_rsp_v && srd_rsp_rdy) srd_rsp_v <= 1'b0;
    else if (srd_v && srd_rdy) begin
      int idx;
      logic [255:0] beat;
      idx = ns - sbase;
      beat = src_beat(idx);
      if (idx == 0 && bad_src) beat[63:32] = APU_VGPU_CLEAR_WORD;
      if (srd_addr != at_src(idx) || srd_len != 32'(APU_VGPU_BEAT_BYTES))
        s_order <= 1'b1;
      sseen <= srd_addr;
      srd_rsp_addr <= srd_addr;
      srd_rsp_len <= srd_len;
      srd_rsp_data <= beat;
      srd_rsp_ok <= !fail_s;
      fail_s <= 1'b0;
      if (idx == 0) bad_src <= 1'b0;
      ns <= ns + 1;
      srd_rsp_v <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nw <= 0;
      w_order <= 1'b0;
      w_data <= 1'b0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      int idx;
      idx = nw - wbase;
      if (wr_addr != at_dst(idx) || wr_len != 32'(APU_VGPU_BEAT_BYTES))
        w_order <= 1'b1;
      if (wr_data != src_beat(idx)) w_data <= 1'b1;
      wseen <= wr_addr;
      wr_rsp_addr <= wr_addr;
      wr_rsp_ok <= !fail_w;
      fail_w <= 1'b0;
      nw <= nw + 1;
      wr_rsp_v <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nd <= 0;
      d_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Beat0;
      if (swap_lanes) beat = {192'b0, beat[31:0], beat[63:32]};
      if (clear_lane) beat[63:32] = APU_VGPU_CLEAR_WORD;
      if (rd_addr != APU_VGPU_RPW_DST ||
          rd_len != 32'(APU_VGPU_BEAT_BYTES)) d_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_d;
      fail_d <= 1'b0;
      swap_lanes <= 1'b0;
      clear_lane <= 1'b0;
      nd <= nd + 1;
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
    cox = '0;
    cox.valid = 1'b1;
    cox.b0 = Origin[7:0];
    cox.word = Origin;
    cox.offset = 16'd0;
    cox.x = 7'd0;
    cox.y = 7'd0;
    csw = '0;
    csw.valid = 1'b1;
    csw.origin = Origin;
    csw.neighbor = Neighbor;
    csw.beats = APU_VGPU_GPW_BEATS;
    csw.src = APU_VGPU_CSW_SRC;
    csw.dst = APU_VGPU_CSW_DST;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = Neighbor[7:0];
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rpx == '0 &&
          off_cpl == '0);
  endtask

  task automatic rpw_step(input apu_vgpu_rpw_status_e st, input string name);
    int rs, rw;
    @(negedge clk);
    while (!rpw_rdy) @(negedge clk);
    cases++;
    rs = ns;
    rw = nw;
    sbase = ns;
    wbase = nw;
    rpw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rpw_req = 1'b0;
    while (!rpw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rpw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RPW_OK) begin
      check("copied", rpw.valid && rpw.origin == Origin &&
            rpw.neighbor == Neighbor && rpw.beats == 16'd512 &&
            rpw.src == APU_VGPU_CSW_DST && rpw.dst == APU_VGPU_RPW_DST &&
            rpw.src != rpw.dst &&
            rpw.cmd == VGPU_CMD_TRANSFER_FROM_HOST_3D &&
            rpw.resource_id == APU_VIRGL_RES_RT &&
            rpw.neighbor != APU_VGPU_CLEAR_WORD);
      check("copy count", ns == rs + 512 && nw == rw + 512 && !s_order &&
            !w_order && !w_data && sseen == APU_VGPU_CSW_TAIL &&
            wseen == APU_VGPU_RPW_TAIL);
    end else if (name == "bad source") begin
      check("one read", ns == rs + 1 && nw == rw && !rpw.valid);
    end else if (name == "bad write") begin
      check("one pair", ns == rs + 1 && nw == rw + 1 && !rpw.valid);
    end else check("no bus", ns == rs && nw == rw);
    @(negedge clk);
    check($sformatf("%s held", name), rpw_cpl_v);
    rpw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rpw_cpl_r = 1'b0;
    while (rpw_cpl_v) @(negedge clk);
  endtask

  task automatic rpr_step(input apu_vgpu_rpr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rpr_rdy) @(negedge clk);
    cases++;
    n0 = nd;
    dbase = nd;
    rpr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rpr_req = 1'b0;
    while (!rpr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rpr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RPR_OK) begin
      check("window", rpr.valid && rpr.origin == Origin &&
            rpr.neighbor == Neighbor && rpr.off1 == 16'd4 &&
            rpr.x1 == 7'd1 && rpr.base == APU_VGPU_RPW_DST &&
            rpr.base != APU_VGPU_CSW_DST);
      check("one read", nd == n0 + 1 && !d_order &&
            rd_seen == APU_VGPU_RPW_DST);
    end else if (name == "bad read" || name == "clear lane" ||
                 name == "swapped lanes") begin
      check("one read failed", nd == n0 + 1 && !rpr.valid);
    end else check("no read", nd == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rpr_cpl_v);
    rpr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rpr_cpl_r = 1'b0;
    while (rpr_cpl_v) @(negedge clk);
  endtask

  task automatic rpx_step(input apu_vgpu_rpx_status_e st, input string name);
    @(negedge clk);
    while (!rpx_rdy) @(negedge clk);
    cases++;
    rpx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rpx_req = 1'b0;
    while (!rpx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rpx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rpx_cpl_v);
    rpx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rpx_cpl_r = 1'b0;
    while (rpx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rpw_req = 1'b0;
    rpr_req = 1'b0;
    rpx_req = 1'b0;
    rpw_cpl_r = 1'b0;
    rpr_cpl_r = 1'b0;
    rpx_cpl_r = 1'b0;
    srd_rsp_v = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    cox = '0;
    csw = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rpw == '0 && rpr == '0 && rpx == '0);
    check("profiles keep the transfer off",
          !ApuOff.RpwEn && !ApuOff.RprEn && !ApuOff.RpxEn &&
          !ApuP1Transport.RpwEn && !ApuP1Transport.RprEn &&
          !ApuP1Transport.RpxEn &&
          !ApuHarness.RpwEn && !ApuHarness.RprEn && !ApuHarness.RpxEn &&
          !ApuSchedBoth.RpwEn && !ApuSchedBoth.RprEn && !ApuSchedBoth.RpxEn &&
          !ApuBadVirglGrant.RpwEn && !ApuBadVirglGrant.RprEn &&
          !ApuBadVirglGrant.RpxEn);
    cfg = ApuP1Transport;
    cfg.RpwEn = 1'b1;
    cfg.RprEn = 1'b1;
    cfg.RpxEn = 1'b1;
    check("transfer does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RpwEn = 1'b1;
    cfg.RprEn = 1'b1;
    cfg.RpxEn = 1'b1;
    check("transfer does not legalize virgl", !apu_cfg_legal(cfg));
    check("transfer places",
          APU_VGPU_RPW_DST == 64'h0000_0000_8807_0000 &&
          APU_VGPU_RPW_TAIL == 64'h0000_0000_8807_3FE0 &&
          APU_VGPU_RPW_DST != APU_VGPU_CSW_DST &&
          APU_VGPU_RPW_DST != APU_VGPU_GPW_ADDR &&
          APU_VGPU_RPW_DST != APU_VGPU_GBW_ADDR &&
          APU_VGPU_RPW_DST != APU_VGPU_ACW_ADDR &&
          VGPU_CMD_TRANSFER_FROM_HOST_3D == 32'h0000_0206 &&
          APU_VIRGL_RES_RT == 32'd4 &&
          Neighbor != APU_VGPU_CLEAR_WORD &&
          Origin != Neighbor &&
          Fill != APU_VGPU_CLEAR_WORD &&
          Neighbor[7:0] != APU_VGPU_CLEAR_R);

    rpw_step(APU_VGPU_RPW_EMPTY, "copy empty");
    rpr_step(APU_VGPU_RPR_EMPTY, "read empty");
    rpx_step(APU_VGPU_RPX_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    rpw_step(APU_VGPU_RPW_FAULT, "bad scissor");
    good_in();
    cox.word = Neighbor;
    rpw_step(APU_VGPU_RPW_FAULT, "wrong origin");
    good_in();
    csw.neighbor = Origin;
    rpw_step(APU_VGPU_RPW_FAULT, "same words");
    good_in();
    bad_src = 1'b1;
    rpw_step(APU_VGPU_RPW_FAULT, "bad source");
    fail_w = 1'b1;
    rpw_step(APU_VGPU_RPW_FAULT, "bad write");
    rpw_step(APU_VGPU_RPW_OK, "copy");
    rpw_step(APU_VGPU_RPW_FAULT, "copy again");
    check("copy stays", rpw.valid && rpw.dst == APU_VGPU_RPW_DST &&
          rpw.cmd == VGPU_CMD_TRANSFER_FROM_HOST_3D &&
          rpw.neighbor == Neighbor && rpw.origin == Origin);
    cxr.height = 16'd64;
    rpr_step(APU_VGPU_RPR_FAULT, "read scissor");
    check("read rejected", !rpr.valid);
    good_in();
    fail_d = 1'b1;
    rpr_step(APU_VGPU_RPR_FAULT, "bad read");
    clear_lane = 1'b1;
    rpr_step(APU_VGPU_RPR_FAULT, "clear lane");
    swap_lanes = 1'b1;
    rpr_step(APU_VGPU_RPR_FAULT, "swapped lanes");
    rpr_step(APU_VGPU_RPR_OK, "read window");
    rpr_step(APU_VGPU_RPR_FAULT, "read again");
    check("read stays", rpr.origin == Origin && rpr.neighbor == Neighbor &&
          rpr.base == APU_VGPU_RPW_DST);
    b0 = APU_VGPU_CLEAR_R;
    rpx_step(APU_VGPU_RPX_FAULT, "clear red first");
    check("clear red rejected", !rpx.valid);
    b0 = APU_VGPU_CLEAR_B;
    rpx_step(APU_VGPU_RPX_FAULT, "blue first");
    check("blue rejected", !rpx.valid);
    b0 = APU_VGPU_CLEAR_A;
    rpx_step(APU_VGPU_RPX_FAULT, "high byte first");
    check("high byte rejected", !rpx.valid);
    b0 = Neighbor[7:0];
    rpx_step(APU_VGPU_RPX_OK, "sample red first");
    check("sample red", rpx.valid && rpx.b0 == 8'h00 && rpx.off1 == 16'd4 &&
          rpx.x1 == 7'd1 && rpx.neighbor == Neighbor);
    rpx_step(APU_VGPU_RPX_FAULT, "order again");
    check("order stays", rpx.b0 == 8'h00 && rpx.off1 == 16'd4);

    pulse_reset();
    check("reset clears", rpw == '0 && rpr == '0 && rpx == '0);
    cox = '0;
    csw = '0;
    cxr = '0;
    rpw_step(APU_VGPU_RPW_EMPTY, "after reset");
    rpr_step(APU_VGPU_RPR_EMPTY, "read after reset");
    rpx_step(APU_VGPU_RPX_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu rpw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rpw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
