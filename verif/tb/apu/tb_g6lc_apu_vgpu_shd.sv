// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_shd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_srx_t srx;
  logic shd_req = 0, shd_rdy, shd_cpl_v, shd_cpl_r = 0;
  apu_vgpu_shd_cpl_t shd_cpl;
  apu_vgpu_shd_t shd;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic shk_req = 0, shk_rdy, shk_cpl_v, shk_cpl_r = 0;
  apu_vgpu_shk_cpl_t shk_cpl;
  apu_vgpu_shk_t shk;
  logic shx_req = 0, shx_rdy, shx_cpl_v, shx_cpl_r = 0;
  apu_vgpu_shx_cpl_t shx_cpl, off_cpl;
  apu_vgpu_shx_t shx, off_shx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_ind = 0, bad_len = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {128'h0, APU_VGPU_QHD_META,
                                  APU_VGPU_QSD_LEN, APU_VGPU_HDR_ADDR};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_shd #(.Enable(1'b1)) i_shd (
    .clk_i(clk), .rst_ni, .srx_i(srx),
    .req_valid_i(shd_req), .req_ready_o(shd_rdy),
    .cpl_valid_o(shd_cpl_v), .cpl_ready_i(shd_cpl_r), .cpl_o(shd_cpl), .shd_o(shd),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_shk #(.Enable(1'b1)) i_shk (
    .clk_i(clk), .rst_ni, .shd_i(shd), .srx_i(srx),
    .req_valid_i(shk_req), .req_ready_o(shk_rdy),
    .cpl_valid_o(shk_cpl_v), .cpl_ready_i(shk_cpl_r), .cpl_o(shk_cpl), .shk_o(shk)
  );
  g6lc_apu_vgpu_shx #(.Enable(1'b1)) i_shx (
    .clk_i(clk), .rst_ni, .shk_i(shk), .shd_i(shd), .srx_i(srx),
    .req_valid_i(shx_req), .req_ready_o(shx_rdy),
    .cpl_valid_o(shx_cpl_v), .cpl_ready_i(shx_cpl_r), .cpl_o(shx_cpl), .shx_o(shx)
  );
  g6lc_apu_vgpu_shx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .shk_i(shk), .shd_i(shd), .srx_i(srx),
    .req_valid_i(shx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(shx_cpl_r), .cpl_o(off_cpl), .shx_o(off_shx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu shd timeout case=%0d", cases); end

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
      if (bad_len) beat[95:64] = APU_VGPU_RAB_BYTES;
      if (rd_addr != APU_VGPU_SHD_ADDR || rd_len != 32'd16) rd_order <= 1'b1;
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
    srx = '0;
    srx.valid = 1'b1;
    srx.desc_id = APU_VGPU_QRG_DESC;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_shx == '0 &&
          off_cpl == '0);
  endtask

  task automatic shd_step(input apu_vgpu_shd_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!shd_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    shd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    shd_req = 1'b0;
    while (!shd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), shd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SHD_OK) begin
      check("desc 0", shd.valid && shd.hdr_addr == APU_VGPU_HDR_ADDR &&
            shd.hdr_addr != APU_VGPU_RAB_CMD &&
            shd.hdr_len == APU_VGPU_QSD_LEN &&
            shd.nxt == 16'd1 && shd.nxt != 16'd2);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_SHD_ADDR && rd_seen != APU_VGPU_QHD_ADDR);
    end else if (name == "bad beat" || name == "indirect" ||
                 name == "short len") begin
      check("one read failed", nread == n0 + 1 && !shd.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), shd_cpl_v);
    shd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    shd_cpl_r = 1'b0;
    while (shd_cpl_v) @(negedge clk);
  endtask

  task automatic shk_step(input apu_vgpu_shk_status_e st, input string name);
    @(negedge clk);
    while (!shk_rdy) @(negedge clk);
    cases++;
    shk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    shk_req = 1'b0;
    while (!shk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), shk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), shk_cpl_v);
    shk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    shk_cpl_r = 1'b0;
    while (shk_cpl_v) @(negedge clk);
  endtask

  task automatic shx_step(input apu_vgpu_shx_status_e st, input string name);
    @(negedge clk);
    while (!shx_rdy) @(negedge clk);
    cases++;
    shx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    shx_req = 1'b0;
    while (!shx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), shx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), shx_cpl_v);
    shx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    shx_cpl_r = 1'b0;
    while (shx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    shd_req = 1'b0;
    shk_req = 1'b0;
    shx_req = 1'b0;
    shd_cpl_r = 1'b0;
    shk_cpl_r = 1'b0;
    shx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    srx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          shd == '0 && shk == '0 && shx == '0);
    check("profiles keep the desc peek off",
          !ApuOff.ShdEn && !ApuOff.ShkEn && !ApuOff.ShxEn &&
          !ApuP1Transport.ShdEn && !ApuP1Transport.ShkEn &&
          !ApuP1Transport.ShxEn &&
          !ApuHarness.ShdEn && !ApuHarness.ShkEn && !ApuHarness.ShxEn &&
          !ApuSchedBoth.ShdEn && !ApuSchedBoth.ShkEn && !ApuSchedBoth.ShxEn &&
          !ApuBadVirglGrant.ShdEn && !ApuBadVirglGrant.ShkEn &&
          !ApuBadVirglGrant.ShxEn);
    cfg = ApuP1Transport;
    cfg.ShdEn = 1'b1;
    cfg.ShkEn = 1'b1;
    cfg.ShxEn = 1'b1;
    check("desc peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.ShdEn = 1'b1;
    cfg.ShkEn = 1'b1;
    cfg.ShxEn = 1'b1;
    check("desc peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("desc places",
          APU_VGPU_SHD_ADDR == 64'h8800E100 &&
          APU_VGPU_SHD_ADDR == APU_VGPU_NXC_DESC &&
          APU_VGPU_SHD_ADDR != APU_VGPU_QHD_ADDR &&
          APU_VGPU_QHD_META == {16'd1, VIRTQ_DESC_F_NEXT} &&
          APU_VGPU_QHD_IND == {16'd1, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT} &&
          APU_VGPU_QHD_JUMP == {16'd2, VIRTQ_DESC_F_NEXT});

    shd_step(APU_VGPU_SHD_EMPTY, "read empty");
    shk_step(APU_VGPU_SHK_EMPTY, "keep empty");
    shx_step(APU_VGPU_SHX_EMPTY, "check empty");
    good_in();
    srx.desc_id = 16'd1;
    shd_step(APU_VGPU_SHD_FAULT, "bad id");
    good_in();
    fail_rd = 1'b1;
    shd_step(APU_VGPU_SHD_FAULT, "bad beat");
    bad_ind = 1'b1;
    shd_step(APU_VGPU_SHD_FAULT, "indirect");
    bad_len = 1'b1;
    shd_step(APU_VGPU_SHD_FAULT, "short len");
    shd_step(APU_VGPU_SHD_OK, "desc 0");
    shd_step(APU_VGPU_SHD_FAULT, "desc again");
    check("desc stays", shd.valid && shd.hdr_addr == APU_VGPU_HDR_ADDR &&
          shd.nxt == 16'd1);
    srx.desc_id = 16'd1;
    shk_step(APU_VGPU_SHK_FAULT, "keep bad id");
    check("keep rejected", !shk.valid);
    good_in();
    shk_step(APU_VGPU_SHK_OK, "keep desc");
    check("desc kept", shk.valid && shk.hdr_addr == APU_VGPU_HDR_ADDR &&
          shk.hdr_len == APU_VGPU_QSD_LEN && shk.nxt == 16'd1);
    shk_step(APU_VGPU_SHK_FAULT, "keep again");
    srx.desc_id = 16'd1;
    shx_step(APU_VGPU_SHX_FAULT, "check bad id");
    check("check rejected", !shx.valid);
    good_in();
    shx_step(APU_VGPU_SHX_OK, "check desc");
    check("desc checked", shx.valid && shx.hdr_addr == APU_VGPU_HDR_ADDR &&
          shx.nxt == 16'd1);
    shx_step(APU_VGPU_SHX_FAULT, "check again");
    check("check stays", shx.hdr_addr == shd.hdr_addr && shx.nxt == shd.nxt);

    pulse_reset();
    check("reset clears", shd == '0 && shk == '0 && shx == '0);
    srx = '0;
    shd_step(APU_VGPU_SHD_EMPTY, "after reset");
    good_in();
    shd_step(APU_VGPU_SHD_OK, "desc after reset");

    if (errors != 0) $fatal(1, "APU vgpu shd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_shd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
