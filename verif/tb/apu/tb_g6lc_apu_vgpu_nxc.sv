// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_nxc;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_sfc_t sfc;
  apu_vgpu_fet_t fet;
  apu_vgpu_iwr_t iwr;
  apu_vgpu_qdr_t qdr;
  logic nxc_req = 0, nxc_rdy, nxc_cpl_v, nxc_cpl_r = 0;
  apu_vgpu_nxc_cpl_t nxc_cpl;
  apu_vgpu_nxc_t nxc;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen0 = 0, seen1 = 0, seen2 = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic nxk_req = 0, nxk_rdy, nxk_cpl_v, nxk_cpl_r = 0;
  apu_vgpu_nxk_cpl_t nxk_cpl, off_cpl;
  apu_vgpu_nxk_t nxk, off_nxk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_link = 0, bad_ind = 0, bad_len = 0;
  logic bad_write = 0, bad_idx = 0, bad_ring = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] D0Meta = {16'd1, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] D1Meta = {16'd2, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] D2Meta = {16'd0, VIRTQ_DESC_F_WRITE};
  localparam logic [31:0] IndMeta = {16'd1, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT};
  localparam logic [31:0] JumpMeta = {16'd2, VIRTQ_DESC_F_NEXT};
  localparam logic [31:0] AvailWord = {16'd1, 16'h0};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_nxc #(.Enable(1'b1)) i_nxc (
    .clk_i(clk), .rst_ni, .sfc_i(sfc), .fet_i(fet), .iwr_i(iwr), .qdr_i(qdr),
    .req_valid_i(nxc_req), .req_ready_o(nxc_rdy),
    .cpl_valid_o(nxc_cpl_v), .cpl_ready_i(nxc_cpl_r), .cpl_o(nxc_cpl), .nxc_o(nxc),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_nxk #(.Enable(1'b1)) i_nxk (
    .clk_i(clk), .rst_ni, .nxc_i(nxc), .sfc_i(sfc), .fet_i(fet), .iwr_i(iwr),
    .qdr_i(qdr), .req_valid_i(nxk_req), .req_ready_o(nxk_rdy),
    .cpl_valid_o(nxk_cpl_v), .cpl_ready_i(nxk_cpl_r), .cpl_o(nxk_cpl), .nxk_o(nxk)
  );
  g6lc_apu_vgpu_nxk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .nxc_i(nxc), .sfc_i(sfc), .fet_i(fet), .iwr_i(iwr),
    .qdr_i(qdr), .req_valid_i(nxk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(nxk_cpl_r), .cpl_o(off_cpl), .nxk_o(off_nxk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu nxc timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      beat_data[63:0] = APU_VGPU_HDR_ADDR;
      beat_data[95:64] = VGPU_SUBMIT_BYTES;
      beat_data[127:96] = bad_ind ? IndMeta : (bad_link ? JumpMeta : D0Meta);
      beat_data[191:128] = APU_VGPU_EXEC_ADDR;
      beat_data[223:192] = bad_len ? 32'd32 : APU_VGPU_SCENE_BYTES;
      beat_data[255:224] = D1Meta;
    end else if (idx == 1) begin
      beat_data[63:0] = APU_VGPU_RSP_ADDR;
      beat_data[95:64] = VGPU_RESP_HDR_BYTES;
      beat_data[127:96] = bad_write ? D0Meta : D2Meta;
      beat_data[191:128] = 64'h1;
    end else begin
      beat_data[31:0] = bad_idx ? {16'd2, 16'h0} : AvailWord;
      beat_data[47:32] = bad_ring ? 16'd1 : 16'd0;
      beat_data[63:48] = 16'h7;
      beat_data[95:64] = 32'h1111_1111;
    end
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      int idx;
      logic [63:0] want;
      idx = nread - run_base;
      want = idx == 0 ? APU_VGPU_NXC_DESC :
             idx == 1 ? APU_VGPU_NXC_LAST : APU_VGPU_NXC_AVAIL;
      if (rd_addr != want) order_bad <= 1'b1;
      if (idx == 0) seen0 <= rd_addr;
      if (idx == 1) seen1 <= rd_addr;
      seen2 <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_data(idx);
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      if (idx == 0) begin
        bad_link <= 1'b0;
        bad_ind <= 1'b0;
        bad_len <= 1'b0;
      end
      if (idx == 1) bad_write <= 1'b0;
      if (idx == 2) begin
        bad_idx <= 1'b0;
        bad_ring <= 1'b0;
      end
      nread <= nread + 1;
      rsp_v <= 1'b1;
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
    sfc = '0;
    sfc.valid = 1'b1;
    sfc.hdr = APU_VIRGL_SF_HDR;
    sfc.handle = APU_VIRGL_SURFACE_HANDLE;
    sfc.resource = APU_VIRGL_RES_RT;
    sfc.format = APU_VIRGL_FMT_B8G8R8X8;
    fet = '0;
    fet.valid = 1'b1;
    fet.kind = VGPU_CMD_SUBMIT_3D;
    fet.cmd0 = Cmd0;
    fet.beats = APU_VGPU_EXEC_BEATS;
    iwr = '0;
    iwr.valid = 1'b1;
    iwr.resource = APU_VIRGL_RES_VBO;
    iwr.nbytes = APU_VIRGL_VBO_BYTES;
    qdr = '0;
    qdr.valid = 1'b1;
    qdr.x0 = APU_VIRGL_F32_NEG_ONE;
  endtask

  function automatic logic chain_ok(input apu_vgpu_nxc_t rec);
    chain_ok = rec.valid && rec.head == 16'd0 && rec.avail_idx == 16'd1 &&
               rec.buf_len == APU_VGPU_SCENE_BYTES &&
               rec.buf_addr == APU_VGPU_EXEC_ADDR &&
               rec.rsp_addr == APU_VGPU_RSP_ADDR && rec.head != rec.avail_idx;
  endfunction

  task automatic nxc_step(input apu_vgpu_nxc_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!nxc_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    nxc_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    nxc_req = 1'b0;
    while (!nxc_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), nxc_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_nxk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_NXC_OK) begin
      check("scene chain", chain_ok(nxc));
      check("read count", nread == n0 + 3 && !order_bad &&
            seen0 == APU_VGPU_NXC_DESC && seen1 == APU_VGPU_NXC_LAST &&
            seen2 == APU_VGPU_NXC_AVAIL);
    end else if (name == "bad beat" || name == "bad link" || name == "bad indirect" ||
                 name == "bad len") begin
      check("one beat", nread == n0 + 1 && !nxc.valid);
    end else if (name == "bad write") begin
      check("two beats", nread == n0 + 2 && !nxc.valid);
    end else if (name == "bad idx" || name == "bad ring") begin
      check("three beats", nread == n0 + 3 && !nxc.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), nxc_cpl_v);
    nxc_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    nxc_cpl_r = 1'b0;
    while (nxc_cpl_v) @(negedge clk);
  endtask

  task automatic nxk_step(input apu_vgpu_nxk_status_e st, input string name);
    @(negedge clk);
    while (!nxk_rdy) @(negedge clk);
    cases++;
    nxk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    nxk_req = 1'b0;
    while (!nxk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), nxk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_nxk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), nxk_cpl_v);
    nxk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    nxk_cpl_r = 1'b0;
    while (nxk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    nxc_req = 1'b0;
    nxk_req = 1'b0;
    nxc_cpl_r = 1'b0;
    nxk_cpl_r = 1'b0;
    rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    sfc = '0;
    fet = '0;
    iwr = '0;
    qdr = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && nxc == '0 &&
          nxk == '0);
    check("profiles keep the chain off",
          !ApuOff.NxcEn && !ApuOff.NxkEn &&
          !ApuP1Transport.NxcEn && !ApuP1Transport.NxkEn &&
          !ApuHarness.NxcEn && !ApuHarness.NxkEn &&
          !ApuSchedBoth.NxcEn && !ApuSchedBoth.NxkEn &&
          !ApuBadVirglGrant.NxcEn && !ApuBadVirglGrant.NxkEn);
    cfg = ApuP1Transport;
    cfg.NxcEn = 1'b1;
    cfg.NxkEn = 1'b1;
    check("chain does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.NxcEn = 1'b1;
    cfg.NxkEn = 1'b1;
    check("chain does not legalize virgl", !apu_cfg_legal(cfg));
    check("chain places",
          APU_VGPU_NXC_DESC == 64'h8800E100 &&
          APU_VGPU_NXC_LAST == 64'h8800E120 &&
          APU_VGPU_NXC_AVAIL == 64'h8800E200 &&
          APU_VGPU_NXC_DESC != APU_VGPU_SUN_ELEM &&
          APU_VGPU_NXC_AVAIL != APU_VGPU_SUN_IDX &&
          APU_VGPU_NXC_DESC != APU_VGPU_EXEC_ADDR &&
          D0Meta == 32'h00010001 && D1Meta == 32'h00020001 &&
          D2Meta == 32'h00000002 && AvailWord == 32'h00010000 &&
          VGPU_SUBMIT_BYTES == 32'd32 && VGPU_RESP_HDR_BYTES == 32'd24 &&
          APU_VGPU_SCENE_BYTES == 32'd960);

    nxc_step(APU_VGPU_NXC_EMPTY, "chain empty");
    good_in();
    sfc = '0;
    nxc_step(APU_VGPU_NXC_EMPTY, "surface missing");
    good_in();
    fet.beats = 6'd0;
    nxc_step(APU_VGPU_NXC_FAULT, "bad identity");
    good_in();
    fail_next = 1'b1;
    nxc_step(APU_VGPU_NXC_FAULT, "bad beat");
    bad_link = 1'b1;
    nxc_step(APU_VGPU_NXC_FAULT, "bad link");
    bad_ind = 1'b1;
    nxc_step(APU_VGPU_NXC_FAULT, "bad indirect");
    bad_len = 1'b1;
    nxc_step(APU_VGPU_NXC_FAULT, "bad len");
    bad_write = 1'b1;
    nxc_step(APU_VGPU_NXC_FAULT, "bad write");
    bad_idx = 1'b1;
    nxc_step(APU_VGPU_NXC_FAULT, "bad idx");
    bad_ring = 1'b1;
    nxc_step(APU_VGPU_NXC_FAULT, "bad ring");
    nxc_step(APU_VGPU_NXC_OK, "scene chain");
    nxc_step(APU_VGPU_NXC_FAULT, "scene chain again");
    check("scene chain stays", chain_ok(nxc) && sfc.handle == APU_VIRGL_SURFACE_HANDLE &&
          nxc.head != sfc.handle[15:0]);
    nxk_step(APU_VGPU_NXK_OK, "keep scene chain");
    check("scene chain kept", nxk.valid && nxk.head == 16'd0 && nxk.avail_idx == 16'd1 &&
          nxk.buf_addr == APU_VGPU_EXEC_ADDR && nxk.rsp_addr == APU_VGPU_RSP_ADDR &&
          nxk.buf_len == APU_VGPU_SCENE_BYTES);
    nxk_step(APU_VGPU_NXK_FAULT, "scene chain keep again");
    check("scene chain keep stays", nxk.avail_idx == 16'd1 &&
          nxk.buf_len == APU_VGPU_SCENE_BYTES);

    pulse_reset();
    check("reset clears", nxc == '0 && nxk == '0);
    zero_in();
    nxc_step(APU_VGPU_NXC_EMPTY, "after reset");
    nxk_step(APU_VGPU_NXK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu nxc errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_nxc cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
