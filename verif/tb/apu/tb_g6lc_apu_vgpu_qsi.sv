// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qsi;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cancel = 0, irq_ack = 0, irq;
  apu_vgpu_qsz_t qsz;
  apu_vgpu_qsu_t qsu;
  logic qsi_req = 0, qsi_rdy, qsi_cpl_v, qsi_cpl_r = 0;
  apu_vgpu_qsi_cpl_t qsi_cpl;
  apu_vgpu_qsi_t qsi;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic qsn_req = 0, qsn_rdy, qsn_cpl_v, qsn_cpl_r = 0;
  apu_vgpu_qsn_cpl_t qsn_cpl;
  apu_vgpu_qsn_t qsn;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qsm_req = 0, qsm_rdy, qsm_cpl_v, qsm_cpl_r = 0;
  apu_vgpu_qsm_cpl_t qsm_cpl, off_cpl;
  apu_vgpu_qsm_t qsm, off_qsm;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, bad_reason = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_QSI_REASON};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qsi #(.Enable(1'b1)) i_qsi (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(irq_ack),
    .qsz_i(qsz), .qsu_i(qsu),
    .req_valid_i(qsi_req), .req_ready_o(qsi_rdy),
    .cpl_valid_o(qsi_cpl_v), .cpl_ready_i(qsi_cpl_r), .cpl_o(qsi_cpl), .qsi_o(qsi),
    .irq_o(irq),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_qsn #(.Enable(1'b1)) i_qsn (
    .clk_i(clk), .rst_ni, .qsi_i(qsi), .qsz_i(qsz),
    .req_valid_i(qsn_req), .req_ready_o(qsn_rdy),
    .cpl_valid_o(qsn_cpl_v), .cpl_ready_i(qsn_cpl_r), .cpl_o(qsn_cpl), .qsn_o(qsn),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qsm #(.Enable(1'b1)) i_qsm (
    .clk_i(clk), .rst_ni, .qsn_i(qsn), .qsi_i(qsi), .qsz_i(qsz),
    .req_valid_i(qsm_req), .req_ready_o(qsm_rdy),
    .cpl_valid_o(qsm_cpl_v), .cpl_ready_i(qsm_cpl_r), .cpl_o(qsm_cpl), .qsm_o(qsm)
  );
  g6lc_apu_vgpu_qsm_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qsn_i(qsn), .qsi_i(qsi), .qsz_i(qsz),
    .req_valid_i(qsm_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qsm_cpl_r), .cpl_o(off_cpl), .qsm_o(off_qsm)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qsi timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
      order_bad <= 1'b0;
      data_bad <= 1'b0;
      stored_v <= 1'b0;
      stored <= '0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      if (wr_addr != APU_VGPU_QSI_ADDR || wr_len != 32'd4) order_bad <= 1'b1;
      if (wr_data[31:0] != APU_VGPU_QSI_REASON) data_bad <= 1'b1;
      wr_seen <= wr_addr;
      stored <= wr_data;
      stored_v <= 1'b1;
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
      logic [255:0] beat;
      beat = stored_v ? stored : Pat;
      if (bad_reason) beat[31:0] = 32'h0;
      if (rd_addr != APU_VGPU_QSI_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_reason <= 1'b0;
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
    qsz = '0;
    qsz.valid = 1'b1;
    qsz.used_idx = APU_VGPU_QSU_IDXV;
    qsz.elem_id = APU_VGPU_QSU_ID;
    qsu = '0;
    qsu.valid = 1'b1;
    qsu.elem_id = APU_VGPU_QSU_ID;
    qsu.elem_len = VGPU_RESP_HDR_BYTES;
    qsu.used_idx = APU_VGPU_QSU_IDXV;
    qsu.elem_addr = APU_VGPU_QSU_ELEM;
    qsu.idx_addr = APU_VGPU_QSU_IDX;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qsm == '0 &&
          off_cpl == '0);
  endtask

  task automatic qsi_step(input apu_vgpu_qsi_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qsi_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    qsi_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsi_req = 1'b0;
    while (!qsi_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsi_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QSI_OK) begin
      check("notified", qsi.valid && qsi.reason == APU_VGPU_QSI_REASON &&
            qsi.used_idx == APU_VGPU_QSU_IDXV &&
            qsi.addr == APU_VGPU_QSI_ADDR &&
            qsi.addr != APU_VGPU_TIW_ADDR && irq == 1'b1);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_QSI_ADDR);
      irq_ack = 1'b1;
      @(posedge clk);
      @(negedge clk);
      irq_ack = 1'b0;
      check("ack lowers the pin", irq == 1'b0 && qsi.valid);
    end else if (name == "bad beat") begin
      check("one write failed", nwrite == n0 + 1 && !qsi.valid && irq == 1'b0);
    end else check("no write", nwrite == n0 && irq == 1'b0);
    @(negedge clk);
    check($sformatf("%s held", name), qsi_cpl_v);
    qsi_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsi_cpl_r = 1'b0;
    while (qsi_cpl_v) @(negedge clk);
  endtask

  task automatic qsn_step(input apu_vgpu_qsn_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qsn_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qsn_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsn_req = 1'b0;
    while (!qsn_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsn_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QSN_OK) begin
      check("echo", qsn.valid && qsn.reason == APU_VGPU_QSI_REASON &&
            qsn.used_idx == APU_VGPU_QSU_IDXV &&
            qsn.addr == APU_VGPU_QSI_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QSI_ADDR);
    end else if (name == "bad read" || name == "zero reason") begin
      check("one read failed", nread == n0 + 1 && !qsn.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qsn_cpl_v);
    qsn_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsn_cpl_r = 1'b0;
    while (qsn_cpl_v) @(negedge clk);
  endtask

  task automatic qsm_step(input apu_vgpu_qsm_status_e st, input string name);
    @(negedge clk);
    while (!qsm_rdy) @(negedge clk);
    cases++;
    qsm_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsm_req = 1'b0;
    while (!qsm_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qsm_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qsm_cpl_v);
    qsm_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qsm_cpl_r = 1'b0;
    while (qsm_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qsi_req = 1'b0;
    qsn_req = 1'b0;
    qsm_req = 1'b0;
    qsi_cpl_r = 1'b0;
    qsn_cpl_r = 1'b0;
    qsm_cpl_r = 1'b0;
    irq_ack = 1'b0;
    cancel = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    stored_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    qsz = '0;
    qsu = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qsi == '0 && qsn == '0 && qsm == '0 && irq == 1'b0);
    check("profiles keep the interrupt off",
          !ApuOff.QsiEn && !ApuOff.QsnEn && !ApuOff.QsmEn &&
          !ApuP1Transport.QsiEn && !ApuP1Transport.QsnEn &&
          !ApuP1Transport.QsmEn &&
          !ApuHarness.QsiEn && !ApuHarness.QsnEn && !ApuHarness.QsmEn &&
          !ApuSchedBoth.QsiEn && !ApuSchedBoth.QsnEn && !ApuSchedBoth.QsmEn &&
          !ApuBadVirglGrant.QsiEn && !ApuBadVirglGrant.QsnEn &&
          !ApuBadVirglGrant.QsmEn);
    cfg = ApuP1Transport;
    cfg.QsiEn = 1'b1;
    cfg.QsnEn = 1'b1;
    cfg.QsmEn = 1'b1;
    check("interrupt does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QsiEn = 1'b1;
    cfg.QsnEn = 1'b1;
    cfg.QsmEn = 1'b1;
    check("interrupt does not legalize virgl", !apu_cfg_legal(cfg));
    check("known interrupt",
          APU_VGPU_QSI_ADDR != APU_VGPU_TIW_ADDR &&
          APU_VGPU_QSI_ADDR != APU_VGPU_QSU_ELEM &&
          APU_VGPU_QSI_REASON == 32'h1 &&
          APU_VGPU_QSU_IDXV != APU_VGPU_TUW_IDXV);

    qsi_step(APU_VGPU_QSI_EMPTY, "write empty");
    qsn_step(APU_VGPU_QSN_EMPTY, "read empty");
    qsm_step(APU_VGPU_QSM_EMPTY, "keep empty");
    good_in();
    cancel = 1'b1;
    qsi_step(APU_VGPU_QSI_FAULT, "cancel");
    cancel = 1'b0;
    fail_wr = 1'b1;
    qsi_step(APU_VGPU_QSI_FAULT, "bad beat");
    qsi_step(APU_VGPU_QSI_OK, "notify");
    qsi_step(APU_VGPU_QSI_FAULT, "notify again");
    fail_rd = 1'b1;
    qsn_step(APU_VGPU_QSN_FAULT, "bad read");
    bad_reason = 1'b1;
    qsn_step(APU_VGPU_QSN_FAULT, "zero reason");
    qsn_step(APU_VGPU_QSN_OK, "echo reason");
    qsn_step(APU_VGPU_QSN_FAULT, "read again");
    qsm_step(APU_VGPU_QSM_OK, "keep reason");
    check("keep reason", qsm.valid && qsm.reason == 32'h1 &&
          qsm.used_idx == 16'd1 && qsm.addr == APU_VGPU_QSI_ADDR &&
          qsm.addr != APU_VGPU_TIW_ADDR);
    qsm_step(APU_VGPU_QSM_FAULT, "keep again");
    check("reason stays", qsm.reason == APU_VGPU_QSI_REASON);

    pulse_reset();
    check("reset clears", qsi == '0 && qsn == '0 && qsm == '0 && irq == 1'b0);
    qsz = '0;
    qsu = '0;
    qsi_step(APU_VGPU_QSI_EMPTY, "after reset");
    good_in();
    qsi_step(APU_VGPU_QSI_OK, "notify after reset");

    if (errors != 0) $fatal(1, "APU vgpu qsi errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qsi cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
