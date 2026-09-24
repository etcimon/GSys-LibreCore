// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qdr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_fet_t fet;
  apu_vgpu_drd_t drd;
  logic qdr_req = 0, qdr_rdy, qdr_cpl_v, qdr_cpl_r = 0;
  apu_vgpu_qdr_cpl_t qdr_cpl;
  apu_vgpu_qdr_t qdr;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_first = 0, seen_last = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic qdk_req = 0, qdk_rdy, qdk_cpl_v, qdk_cpl_r = 0;
  apu_vgpu_qdk_cpl_t qdk_cpl, off_cpl;
  apu_vgpu_qdk_t qdk, off_qdk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_prefix = 0, bad_x0 = 0, bad_mid = 0, bad_last = 0;
  logic order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] VbHdr = {16'd3, 8'd0, APU_VIRGL_SET_VERTEX_BUFFERS};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_qdr #(.Enable(1'b1)) i_qdr (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd),
    .req_valid_i(qdr_req), .req_ready_o(qdr_rdy),
    .cpl_valid_o(qdr_cpl_v), .cpl_ready_i(qdr_cpl_r), .cpl_o(qdr_cpl), .qdr_o(qdr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_qdk #(.Enable(1'b1)) i_qdk (
    .clk_i(clk), .rst_ni, .qdr_i(qdr), .fet_i(fet), .drd_i(drd),
    .req_valid_i(qdk_req), .req_ready_o(qdk_rdy),
    .cpl_valid_o(qdk_cpl_v), .cpl_ready_i(qdk_cpl_r), .cpl_o(qdk_cpl), .qdk_o(qdk)
  );
  g6lc_apu_vgpu_qdk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qdr_i(qdr), .fet_i(fet), .drd_i(drd),
    .req_valid_i(qdk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qdk_cpl_r), .cpl_o(off_cpl), .qdk_o(off_qdk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qdr timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [31:0] quad_word(input int i);
    case (i)
      0, 1, 7, 12: quad_word = APU_VIRGL_F32_NEG_ONE;
      3, 6, 9, 10, 13, 15, 17, 18, 19, 21, 22, 23: quad_word = APU_VIRGL_F32_ONE;
      default: quad_word = 32'h0;
    endcase
  endfunction

  function automatic logic [255:0] beat_data(input int idx);
    beat_data = '0;
    if (idx == 0) begin
      beat_data[127:96] = bad_prefix ? 32'h0 : APU_VIRGL_VBO_BYTES;
      beat_data[159:128] = 32'd1;
      beat_data[191:160] = 32'd1;
      beat_data[223:192] = bad_x0 ? 32'h0 : quad_word(0);
      beat_data[255:224] = quad_word(1);
    end else if (idx == 1) begin
      beat_data[31:0] = quad_word(2);
      beat_data[63:32] = quad_word(3);
      beat_data[95:64] = quad_word(4);
      beat_data[127:96] = quad_word(5);
      beat_data[159:128] = quad_word(6);
      beat_data[191:160] = quad_word(7);
      beat_data[223:192] = quad_word(8);
      beat_data[255:224] = quad_word(9);
    end else if (idx == 2) begin
      beat_data[31:0] = quad_word(10);
      beat_data[63:32] = quad_word(11);
      beat_data[95:64] = bad_mid ? 32'h0 : quad_word(12);
      beat_data[127:96] = quad_word(13);
      beat_data[159:128] = quad_word(14);
      beat_data[191:160] = quad_word(15);
      beat_data[223:192] = quad_word(16);
      beat_data[255:224] = quad_word(17);
    end else begin
      beat_data[31:0] = quad_word(18);
      beat_data[63:32] = quad_word(19);
      beat_data[95:64] = quad_word(20);
      beat_data[127:96] = quad_word(21);
      beat_data[159:128] = quad_word(22);
      beat_data[191:160] = bad_last ? 32'h0 : quad_word(23);
      // The vertex-buffer command follows the floats and is not part of them.
      beat_data[223:192] = VbHdr;
      beat_data[255:224] = APU_VIRGL_VERT_STRIDE;
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
      want = APU_VGPU_QUAD_ADDR + (64'(idx) << 5);
      if (rd_addr != want) order_bad <= 1'b1;
      if (idx == 0) seen_first <= rd_addr;
      seen_last <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_data(idx);
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      if (idx == 0) begin
        bad_prefix <= 1'b0;
        bad_x0 <= 1'b0;
      end
      if (idx == 2) bad_mid <= 1'b0;
      if (idx == 3) bad_last <= 1'b0;
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
    fet = '0;
    fet.valid = 1'b1;
    fet.kind = VGPU_CMD_SUBMIT_3D;
    fet.cmd0 = Cmd0;
    fet.beats = APU_VGPU_EXEC_BEATS;
    drd = '0;
    drd.valid = 1'b1;
    drd.count = APU_VIRGL_VERT_COUNT;
    drd.prim = APU_VIRGL_PRIM_STRIP;
  endtask

  task automatic qdr_step(input apu_vgpu_qdr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qdr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    qdr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qdr_req = 1'b0;
    while (!qdr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qdr_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qdk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_QDR_OK) begin
      check("quad read", qdr.valid && qdr.x0 == APU_VIRGL_F32_NEG_ONE &&
            qdr.last == APU_VIRGL_F32_ONE && qdr.x0 != qdr.last);
      check("read count", nread == n0 + 4 && !order_bad &&
            seen_first == APU_VGPU_QUAD_ADDR && seen_last == APU_VGPU_QUAD_LAST);
    end else if (name == "bad beat" || name == "bad prefix" || name == "bad x0") begin
      check("one beat", nread == n0 + 1 && !qdr.valid);
    end else if (name == "bad mid") begin
      check("three beats", nread == n0 + 3 && !qdr.valid);
    end else if (name == "bad last") begin
      check("four beats", nread == n0 + 4 && !qdr.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), qdr_cpl_v);
    qdr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qdr_cpl_r = 1'b0;
    while (qdr_cpl_v) @(negedge clk);
  endtask

  task automatic qdk_step(input apu_vgpu_qdk_status_e st, input string name);
    @(negedge clk);
    while (!qdk_rdy) @(negedge clk);
    cases++;
    qdk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qdk_req = 1'b0;
    while (!qdk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qdk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qdk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), qdk_cpl_v);
    qdk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qdk_cpl_r = 1'b0;
    while (qdk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qdr_req = 1'b0;
    qdk_req = 1'b0;
    qdr_cpl_r = 1'b0;
    qdk_cpl_r = 1'b0;
    rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    fet = '0;
    drd = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && qdr == '0 &&
          qdk == '0);
    check("profiles keep the quad off",
          !ApuOff.QdrEn && !ApuOff.QdkEn &&
          !ApuP1Transport.QdrEn && !ApuP1Transport.QdkEn &&
          !ApuHarness.QdrEn && !ApuHarness.QdkEn &&
          !ApuSchedBoth.QdrEn && !ApuSchedBoth.QdkEn &&
          !ApuBadVirglGrant.QdrEn && !ApuBadVirglGrant.QdkEn);
    cfg = ApuP1Transport;
    cfg.QdrEn = 1'b1;
    cfg.QdkEn = 1'b1;
    check("quad read does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.QdrEn = 1'b1;
    cfg.QdkEn = 1'b1;
    check("quad read does not legalize virgl", !apu_cfg_legal(cfg));
    check("quad place", APU_VGPU_QUAD_BEAT == 6'd21 &&
          APU_VGPU_QUAD_ADDR == 64'h8800B2A0 &&
          APU_VGPU_QUAD_LAST == 64'h8800B300 &&
          APU_VIRGL_QUAD_AT == 32'd696 &&
          APU_VIRGL_F32_NEG_ONE == 32'hbf800000 &&
          APU_VIRGL_F32_ONE == 32'h3f800000 &&
          VbHdr == 32'h00030006);

    qdr_step(APU_VGPU_QDR_EMPTY, "qdr empty");
    fet.valid = 1'b1;
    fet.kind = VGPU_CMD_SUBMIT_3D;
    fet.cmd0 = Cmd0;
    fet.beats = APU_VGPU_EXEC_BEATS;
    qdr_step(APU_VGPU_QDR_EMPTY, "draw missing");
    good_in();
    fet.beats = 6'd0;
    qdr_step(APU_VGPU_QDR_FAULT, "bad identity");
    good_in();
    fail_next = 1'b1;
    qdr_step(APU_VGPU_QDR_FAULT, "bad beat");
    bad_prefix = 1'b1;
    qdr_step(APU_VGPU_QDR_FAULT, "bad prefix");
    bad_x0 = 1'b1;
    qdr_step(APU_VGPU_QDR_FAULT, "bad x0");
    bad_mid = 1'b1;
    qdr_step(APU_VGPU_QDR_FAULT, "bad mid");
    bad_last = 1'b1;
    qdr_step(APU_VGPU_QDR_FAULT, "bad last");
    qdr_step(APU_VGPU_QDR_OK, "quad read");
    qdr_step(APU_VGPU_QDR_FAULT, "quad again");
    check("quad stays", qdr.valid && qdr.x0 == APU_VIRGL_F32_NEG_ONE &&
          qdr.last == APU_VIRGL_F32_ONE);
    qdk_step(APU_VGPU_QDK_OK, "keep quad");
    check("quad kept", qdk.valid && qdk.x0 == APU_VIRGL_F32_NEG_ONE &&
          qdk.last == APU_VIRGL_F32_ONE && qdk.x0 != qdk.last);
    qdk_step(APU_VGPU_QDK_FAULT, "quad keep again");
    check("quad keep stays", qdk.x0 == APU_VIRGL_F32_NEG_ONE &&
          qdk.last == APU_VIRGL_F32_ONE);

    pulse_reset();
    check("reset clears", qdr == '0 && qdk == '0);
    fet = '0;
    drd = '0;
    qdr_step(APU_VGPU_QDR_EMPTY, "after reset");
    qdk_step(APU_VGPU_QDK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu qdr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qdr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
