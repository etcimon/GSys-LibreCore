// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rhd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_rrx_t rrx;
  logic rhd_req = 0, rhd_rdy, rhd_cpl_v, rhd_cpl_r = 0;
  apu_vgpu_rhd_cpl_t rhd_cpl;
  apu_vgpu_rhd_t rhd;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic rhk_req = 0, rhk_rdy, rhk_cpl_v, rhk_cpl_r = 0;
  apu_vgpu_rhk_cpl_t rhk_cpl;
  apu_vgpu_rhk_t rhk;
  logic rhx_req = 0, rhx_rdy, rhx_cpl_v, rhx_cpl_r = 0;
  apu_vgpu_rhx_cpl_t rhx_cpl, off_cpl;
  apu_vgpu_rhx_t rhx, off_rhx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_ind = 0, bad_len = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {128'h0, APU_VGPU_QHD_META,
                                  APU_VGPU_RAB_BYTES, APU_VGPU_RAB_CMD};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_rhd #(.Enable(1'b1)) i_rhd (
    .clk_i(clk), .rst_ni, .rrx_i(rrx),
    .req_valid_i(rhd_req), .req_ready_o(rhd_rdy),
    .cpl_valid_o(rhd_cpl_v), .cpl_ready_i(rhd_cpl_r), .cpl_o(rhd_cpl), .rhd_o(rhd),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rhk #(.Enable(1'b1)) i_rhk (
    .clk_i(clk), .rst_ni, .rhd_i(rhd), .rrx_i(rrx),
    .req_valid_i(rhk_req), .req_ready_o(rhk_rdy),
    .cpl_valid_o(rhk_cpl_v), .cpl_ready_i(rhk_cpl_r), .cpl_o(rhk_cpl), .rhk_o(rhk)
  );
  g6lc_apu_vgpu_rhx #(.Enable(1'b1)) i_rhx (
    .clk_i(clk), .rst_ni, .rhk_i(rhk), .rhd_i(rhd), .rrx_i(rrx),
    .req_valid_i(rhx_req), .req_ready_o(rhx_rdy),
    .cpl_valid_o(rhx_cpl_v), .cpl_ready_i(rhx_cpl_r), .cpl_o(rhx_cpl), .rhx_o(rhx)
  );
  g6lc_apu_vgpu_rhx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rhk_i(rhk), .rhd_i(rhd), .rrx_i(rrx),
    .req_valid_i(rhx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rhx_cpl_r), .cpl_o(off_cpl), .rhx_o(off_rhx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rhd timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_ind) beat[127:96] = APU_VGPU_QHD_IND;
      if (bad_len) beat[95:64] = APU_VGPU_TFB_BYTES;
      if (rd_addr != APU_VGPU_QHD_ADDR || rd_len != 32'd16) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_ind <= 1'b0;
      bad_len <= 1'b0;
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
    rrx = '0;
    rrx.valid = 1'b1;
    rrx.desc_id = APU_VGPU_QRG_DESC;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rhx == '0 &&
          off_cpl == '0);
  endtask

  task automatic rhd_step(input apu_vgpu_rhd_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rhd_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rhd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rhd_req = 1'b0;
    while (!rhd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rhd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RHD_OK) begin
      check("desc 0", rhd.valid && rhd.att_addr == APU_VGPU_RAB_CMD &&
            rhd.att_addr != APU_VGPU_NXC_DESC &&
            rhd.att_len == APU_VGPU_RAB_BYTES &&
            rhd.nxt == 16'd1 && rhd.nxt != 16'd2);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QHD_ADDR && rd_seen != APU_VGPU_QHD_SCENE);
    end else if (name == "bad beat" || name == "indirect" ||
                 name == "short len") begin
      check("one read failed", nread == n0 + 1 && !rhd.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rhd_cpl_v);
    rhd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rhd_cpl_r = 1'b0;
    while (rhd_cpl_v) @(negedge clk);
  endtask

  task automatic rhk_step(input apu_vgpu_rhk_status_e st, input string name);
    @(negedge clk);
    while (!rhk_rdy) @(negedge clk);
    cases++;
    rhk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rhk_req = 1'b0;
    while (!rhk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rhk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rhk_cpl_v);
    rhk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rhk_cpl_r = 1'b0;
    while (rhk_cpl_v) @(negedge clk);
  endtask

  task automatic rhx_step(input apu_vgpu_rhx_status_e st, input string name);
    @(negedge clk);
    while (!rhx_rdy) @(negedge clk);
    cases++;
    rhx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rhx_req = 1'b0;
    while (!rhx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rhx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rhx_cpl_v);
    rhx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rhx_cpl_r = 1'b0;
    while (rhx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rhd_req = 1'b0;
    rhk_req = 1'b0;
    rhx_req = 1'b0;
    rhd_cpl_r = 1'b0;
    rhk_cpl_r = 1'b0;
    rhx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    rrx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rhd == '0 && rhk == '0 && rhx == '0);
    check("profiles keep the desc peek off",
          !ApuOff.RhdEn && !ApuOff.RhkEn && !ApuOff.RhxEn &&
          !ApuP1Transport.RhdEn && !ApuP1Transport.RhkEn &&
          !ApuP1Transport.RhxEn &&
          !ApuHarness.RhdEn && !ApuHarness.RhkEn && !ApuHarness.RhxEn &&
          !ApuSchedBoth.RhdEn && !ApuSchedBoth.RhkEn && !ApuSchedBoth.RhxEn &&
          !ApuBadVirglGrant.RhdEn && !ApuBadVirglGrant.RhkEn &&
          !ApuBadVirglGrant.RhxEn);
    cfg = ApuP1Transport;
    cfg.RhdEn = 1'b1;
    cfg.RhkEn = 1'b1;
    cfg.RhxEn = 1'b1;
    check("desc peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RhdEn = 1'b1;
    cfg.RhkEn = 1'b1;
    cfg.RhxEn = 1'b1;
    check("desc peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("desc places",
          APU_VGPU_QHD_ADDR == 64'h880D0000 &&
          APU_VGPU_QHD_ADDR == APU_VGPU_TXC_DESC &&
          APU_VGPU_QHD_SCENE == APU_VGPU_NXC_DESC &&
          APU_VGPU_QHD_META == {16'd1, VIRTQ_DESC_F_NEXT} &&
          APU_VGPU_QHD_IND == {16'd1, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT} &&
          APU_VGPU_QHD_JUMP == {16'd2, VIRTQ_DESC_F_NEXT});

    rhd_step(APU_VGPU_RHD_EMPTY, "read empty");
    rhk_step(APU_VGPU_RHK_EMPTY, "keep empty");
    rhx_step(APU_VGPU_RHX_EMPTY, "check empty");
    good_in();
    rrx.desc_id = 16'd1;
    rhd_step(APU_VGPU_RHD_FAULT, "bad id");
    good_in();
    fail_rd = 1'b1;
    rhd_step(APU_VGPU_RHD_FAULT, "bad beat");
    bad_ind = 1'b1;
    rhd_step(APU_VGPU_RHD_FAULT, "indirect");
    bad_len = 1'b1;
    rhd_step(APU_VGPU_RHD_FAULT, "short len");
    rhd_step(APU_VGPU_RHD_OK, "desc 0");
    rhd_step(APU_VGPU_RHD_FAULT, "desc again");
    check("desc stays", rhd.valid && rhd.att_addr == APU_VGPU_RAB_CMD &&
          rhd.nxt == 16'd1);
    rrx.desc_id = 16'd1;
    rhk_step(APU_VGPU_RHK_FAULT, "keep bad id");
    check("keep rejected", !rhk.valid);
    good_in();
    rhk_step(APU_VGPU_RHK_OK, "keep desc");
    check("desc kept", rhk.valid && rhk.att_addr == APU_VGPU_RAB_CMD &&
          rhk.att_len == APU_VGPU_RAB_BYTES && rhk.nxt == 16'd1);
    rhk_step(APU_VGPU_RHK_FAULT, "keep again");
    rrx.desc_id = 16'd1;
    rhx_step(APU_VGPU_RHX_FAULT, "check bad id");
    check("check rejected", !rhx.valid);
    good_in();
    rhx_step(APU_VGPU_RHX_OK, "check desc");
    check("desc checked", rhx.valid && rhx.att_addr == APU_VGPU_RAB_CMD &&
          rhx.nxt == 16'd1);
    rhx_step(APU_VGPU_RHX_FAULT, "check again");
    check("check stays", rhx.att_addr == rhd.att_addr && rhx.nxt == rhd.nxt);

    pulse_reset();
    check("reset clears", rhd == '0 && rhk == '0 && rhx == '0);
    rrx = '0;
    rhd_step(APU_VGPU_RHD_EMPTY, "after reset");
    good_in();
    rhd_step(APU_VGPU_RHD_OK, "desc after reset");

    if (errors != 0) $fatal(1, "APU vgpu rhd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rhd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
