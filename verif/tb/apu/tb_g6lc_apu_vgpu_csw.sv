// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_csw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_acx_t acx;
  apu_vgpu_rbf_t rbf;
  apu_vgpu_cxr_t cxr;
  logic csw_req = 0, csw_rdy, csw_cpl_v, csw_cpl_r = 0;
  apu_vgpu_csw_cpl_t csw_cpl;
  apu_vgpu_csw_t csw;
  logic srd_v, srd_rdy, srd_rsp_v = 0, srd_rsp_rdy, srd_rsp_ok = 0;
  logic [63:0] srd_addr, srd_rsp_addr = 0, sseen = 0;
  logic [31:0] srd_len, srd_rsp_len = 0;
  logic [255:0] srd_rsp_data = 0;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wseen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic csr_req = 0, csr_rdy, csr_cpl_v, csr_cpl_r = 0;
  apu_vgpu_csr_cpl_t csr_cpl;
  apu_vgpu_csr_t csr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic [7:0] b0 = 0;
  logic csx_req = 0, csx_rdy, csx_cpl_v, csx_cpl_r = 0;
  apu_vgpu_csx_cpl_t csx_cpl, off_cpl;
  apu_vgpu_csx_t csx, off_csx;
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

  g6lc_apu_vgpu_csw #(.Enable(1'b1)) i_csw (
    .clk_i(clk), .rst_ni, .acx_i(acx), .rbf_i(rbf), .cxr_i(cxr),
    .req_valid_i(csw_req), .req_ready_o(csw_rdy),
    .cpl_valid_o(csw_cpl_v), .cpl_ready_i(csw_cpl_r), .cpl_o(csw_cpl), .csw_o(csw),
    .rd_valid_o(srd_v), .rd_ready_i(srd_rdy), .rd_addr_o(srd_addr), .rd_len_o(srd_len),
    .rd_rsp_valid_i(srd_rsp_v), .rd_rsp_ready_o(srd_rsp_rdy), .rd_rsp_ok_i(srd_rsp_ok),
    .rd_rsp_addr_i(srd_rsp_addr), .rd_rsp_len_i(srd_rsp_len), .rd_rsp_data_i(srd_rsp_data),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_csr #(.Enable(1'b1)) i_csr (
    .clk_i(clk), .rst_ni, .csw_i(csw), .acx_i(acx), .cxr_i(cxr),
    .req_valid_i(csr_req), .req_ready_o(csr_rdy),
    .cpl_valid_o(csr_cpl_v), .cpl_ready_i(csr_cpl_r), .cpl_o(csr_cpl), .csr_o(csr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_csx #(.Enable(1'b1)) i_csx (
    .clk_i(clk), .rst_ni, .csr_i(csr), .b0_i(b0),
    .req_valid_i(csx_req), .req_ready_o(csx_rdy),
    .cpl_valid_o(csx_cpl_v), .cpl_ready_i(csx_cpl_r), .cpl_o(csx_cpl), .csx_o(csx)
  );
  g6lc_apu_vgpu_csx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .csr_i(csr), .b0_i(b0),
    .req_valid_i(csx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(csx_cpl_r), .cpl_o(off_cpl), .csx_o(off_csx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu csw timeout case=%0d s=%0d", cases, ns); end

  function automatic logic [255:0] src_beat(input int idx);
    if (idx == 0) src_beat = Beat0;
    else src_beat = FillBeat;
  endfunction
  function automatic logic [63:0] at_src(input int idx);
    at_src = APU_VGPU_CSW_SRC + (64'(idx) << 5);
  endfunction
  function automatic logic [63:0] at_dst(input int idx);
    at_dst = APU_VGPU_CSW_DST + (64'(idx) << 5);
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
      if (rd_addr != APU_VGPU_CSW_DST ||
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
    acx = '0;
    acx.valid = 1'b1;
    acx.format = APU_VIRGL_FMT_B8G8R8X8;
    acx.off0 = APU_VGPU_ACW_AT0;
    acx.off1 = APU_VGPU_ACW_AT1;
    acx.x0 = 7'd0;
    acx.x1 = 7'd1;
    acx.b0 = Neighbor[7:0];
    acx.origin = Origin;
    acx.neighbor = Neighbor;
    rbf = '0;
    rbf.valid = 1'b1;
    rbf.word0 = Origin;
    rbf.bytes = APU_VGPU_CEIL_BYTES;
    rbf.beats = APU_VGPU_CEIL_BEATS;
    rbf.last_addr = APU_VGPU_CSW_SRC_TAIL;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = Neighbor[7:0];
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_csx == '0 &&
          off_cpl == '0);
  endtask

  task automatic csw_step(input apu_vgpu_csw_status_e st, input string name);
    int rs, rw;
    @(negedge clk);
    while (!csw_rdy) @(negedge clk);
    cases++;
    rs = ns;
    rw = nw;
    sbase = ns;
    wbase = nw;
    csw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    csw_req = 1'b0;
    while (!csw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), csw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_CSW_OK) begin
      check("copied", csw.valid && csw.origin == Origin &&
            csw.neighbor == Neighbor && csw.beats == 16'd512 &&
            csw.src == APU_VGPU_CSW_SRC && csw.dst == APU_VGPU_CSW_DST &&
            csw.src != csw.dst && csw.neighbor != APU_VGPU_CLEAR_WORD);
      check("copy count", ns == rs + 512 && nw == rw + 512 && !s_order &&
            !w_order && !w_data && sseen == APU_VGPU_CSW_SRC_TAIL &&
            wseen == APU_VGPU_CSW_TAIL);
    end else if (name == "bad source") begin
      check("one read", ns == rs + 1 && nw == rw && !csw.valid);
    end else if (name == "bad write") begin
      check("one pair", ns == rs + 1 && nw == rw + 1 && !csw.valid);
    end else check("no bus", ns == rs && nw == rw);
    @(negedge clk);
    check($sformatf("%s held", name), csw_cpl_v);
    csw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    csw_cpl_r = 1'b0;
    while (csw_cpl_v) @(negedge clk);
  endtask

  task automatic csr_step(input apu_vgpu_csr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!csr_rdy) @(negedge clk);
    cases++;
    n0 = nd;
    dbase = nd;
    csr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    csr_req = 1'b0;
    while (!csr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), csr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_CSR_OK) begin
      check("window", csr.valid && csr.origin == Origin &&
            csr.neighbor == Neighbor && csr.off1 == 16'd4 &&
            csr.x1 == 7'd1 && csr.base == APU_VGPU_CSW_DST &&
            csr.base != APU_VGPU_ACW_ADDR);
      check("one read", nd == n0 + 1 && !d_order &&
            rd_seen == APU_VGPU_CSW_DST);
    end else if (name == "bad read" || name == "clear lane" ||
                 name == "swapped lanes") begin
      check("one read failed", nd == n0 + 1 && !csr.valid);
    end else check("no read", nd == n0);
    @(negedge clk);
    check($sformatf("%s held", name), csr_cpl_v);
    csr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    csr_cpl_r = 1'b0;
    while (csr_cpl_v) @(negedge clk);
  endtask

  task automatic csx_step(input apu_vgpu_csx_status_e st, input string name);
    @(negedge clk);
    while (!csx_rdy) @(negedge clk);
    cases++;
    csx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    csx_req = 1'b0;
    while (!csx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), csx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), csx_cpl_v);
    csx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    csx_cpl_r = 1'b0;
    while (csx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    csw_req = 1'b0;
    csr_req = 1'b0;
    csx_req = 1'b0;
    csw_cpl_r = 1'b0;
    csr_cpl_r = 1'b0;
    csx_cpl_r = 1'b0;
    srd_rsp_v = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    acx = '0;
    rbf = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          csw == '0 && csr == '0 && csx == '0);
    check("profiles keep the copy off",
          !ApuOff.CswEn && !ApuOff.CsrEn && !ApuOff.CsxEn &&
          !ApuP1Transport.CswEn && !ApuP1Transport.CsrEn &&
          !ApuP1Transport.CsxEn &&
          !ApuHarness.CswEn && !ApuHarness.CsrEn && !ApuHarness.CsxEn &&
          !ApuSchedBoth.CswEn && !ApuSchedBoth.CsrEn && !ApuSchedBoth.CsxEn &&
          !ApuBadVirglGrant.CswEn && !ApuBadVirglGrant.CsrEn &&
          !ApuBadVirglGrant.CsxEn);
    cfg = ApuP1Transport;
    cfg.CswEn = 1'b1;
    cfg.CsrEn = 1'b1;
    cfg.CsxEn = 1'b1;
    check("copy does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.CswEn = 1'b1;
    cfg.CsrEn = 1'b1;
    cfg.CsxEn = 1'b1;
    check("copy does not legalize virgl", !apu_cfg_legal(cfg));
    check("copy places",
          APU_VGPU_CSW_SRC == 64'h0000_0000_8804_0000 &&
          APU_VGPU_CSW_DST == 64'h0000_0000_8806_0000 &&
          APU_VGPU_CSW_TAIL == 64'h0000_0000_8806_3FE0 &&
          APU_VGPU_CSW_SRC_TAIL == 64'h0000_0000_8804_3FE0 &&
          APU_VGPU_CSW_DST != APU_VGPU_ACW_ADDR &&
          APU_VGPU_CSW_DST != APU_VGPU_GPW_ADDR &&
          APU_VGPU_CSW_DST != APU_VGPU_GBW_ADDR &&
          APU_VGPU_CSW_SRC != APU_VGPU_CSW_DST &&
          Neighbor != APU_VGPU_CLEAR_WORD &&
          Origin != Neighbor &&
          Fill != APU_VGPU_CLEAR_WORD &&
          Neighbor[7:0] != APU_VGPU_CLEAR_R);

    csw_step(APU_VGPU_CSW_EMPTY, "copy empty");
    csr_step(APU_VGPU_CSR_EMPTY, "read empty");
    csx_step(APU_VGPU_CSX_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    csw_step(APU_VGPU_CSW_FAULT, "bad scissor");
    good_in();
    rbf.word0 = Neighbor;
    csw_step(APU_VGPU_CSW_FAULT, "wrong word0");
    good_in();
    acx.neighbor = Origin;
    csw_step(APU_VGPU_CSW_FAULT, "same words");
    good_in();
    bad_src = 1'b1;
    csw_step(APU_VGPU_CSW_FAULT, "bad source");
    fail_w = 1'b1;
    csw_step(APU_VGPU_CSW_FAULT, "bad write");
    csw_step(APU_VGPU_CSW_OK, "copy");
    csw_step(APU_VGPU_CSW_FAULT, "copy again");
    check("copy stays", csw.valid && csw.dst == APU_VGPU_CSW_DST &&
          csw.neighbor == Neighbor && csw.origin == Origin);
    cxr.height = 16'd64;
    csr_step(APU_VGPU_CSR_FAULT, "read scissor");
    check("read rejected", !csr.valid);
    good_in();
    fail_d = 1'b1;
    csr_step(APU_VGPU_CSR_FAULT, "bad read");
    clear_lane = 1'b1;
    csr_step(APU_VGPU_CSR_FAULT, "clear lane");
    swap_lanes = 1'b1;
    csr_step(APU_VGPU_CSR_FAULT, "swapped lanes");
    csr_step(APU_VGPU_CSR_OK, "read window");
    csr_step(APU_VGPU_CSR_FAULT, "read again");
    check("read stays", csr.origin == Origin && csr.neighbor == Neighbor &&
          csr.base == APU_VGPU_CSW_DST);
    b0 = APU_VGPU_CLEAR_R;
    csx_step(APU_VGPU_CSX_FAULT, "clear red first");
    check("clear red rejected", !csx.valid);
    b0 = APU_VGPU_CLEAR_B;
    csx_step(APU_VGPU_CSX_FAULT, "blue first");
    check("blue rejected", !csx.valid);
    b0 = APU_VGPU_CLEAR_A;
    csx_step(APU_VGPU_CSX_FAULT, "high byte first");
    check("high byte rejected", !csx.valid);
    b0 = Neighbor[7:0];
    csx_step(APU_VGPU_CSX_OK, "sample red first");
    check("sample red", csx.valid && csx.b0 == 8'h00 && csx.off1 == 16'd4 &&
          csx.x1 == 7'd1 && csx.neighbor == Neighbor);
    csx_step(APU_VGPU_CSX_FAULT, "order again");
    check("order stays", csx.b0 == 8'h00 && csx.off1 == 16'd4);

    pulse_reset();
    check("reset clears", csw == '0 && csr == '0 && csx == '0);
    acx = '0;
    rbf = '0;
    cxr = '0;
    csw_step(APU_VGPU_CSW_EMPTY, "after reset");
    csr_step(APU_VGPU_CSR_EMPTY, "read after reset");
    csx_step(APU_VGPU_CSX_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu csw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_csw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
