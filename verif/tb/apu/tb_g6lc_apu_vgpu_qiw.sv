// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_qiw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cancel = 0, irq_ack = 0, irq;
  apu_vgpu_qux_t qux;
  apu_vgpu_quw_t quw;
  logic qiw_req = 0, qiw_rdy, qiw_cpl_v, qiw_cpl_r = 0;
  apu_vgpu_qiw_cpl_t qiw_cpl;
  apu_vgpu_qiw_t qiw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic qir_req = 0, qir_rdy, qir_cpl_v, qir_cpl_r = 0;
  apu_vgpu_qir_cpl_t qir_cpl;
  apu_vgpu_qir_t qir;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic qix_req = 0, qix_rdy, qix_cpl_v, qix_cpl_r = 0;
  apu_vgpu_qix_cpl_t qix_cpl, off_cpl;
  apu_vgpu_qix_t qix, off_qix;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, bad_reason = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_TIW_REASON};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_qiw #(.Enable(1'b1)) i_qiw (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(irq_ack),
    .qux_i(qux), .quw_i(quw),
    .req_valid_i(qiw_req), .req_ready_o(qiw_rdy),
    .cpl_valid_o(qiw_cpl_v), .cpl_ready_i(qiw_cpl_r), .cpl_o(qiw_cpl), .qiw_o(qiw),
    .irq_o(irq),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_qir #(.Enable(1'b1)) i_qir (
    .clk_i(clk), .rst_ni, .qiw_i(qiw), .qux_i(qux),
    .req_valid_i(qir_req), .req_ready_o(qir_rdy),
    .cpl_valid_o(qir_cpl_v), .cpl_ready_i(qir_cpl_r), .cpl_o(qir_cpl), .qir_o(qir),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_qix #(.Enable(1'b1)) i_qix (
    .clk_i(clk), .rst_ni, .qir_i(qir), .qiw_i(qiw), .qux_i(qux),
    .req_valid_i(qix_req), .req_ready_o(qix_rdy),
    .cpl_valid_o(qix_cpl_v), .cpl_ready_i(qix_cpl_r), .cpl_o(qix_cpl), .qix_o(qix)
  );
  g6lc_apu_vgpu_qix_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .qir_i(qir), .qiw_i(qiw), .qux_i(qux),
    .req_valid_i(qix_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(qix_cpl_r), .cpl_o(off_cpl), .qix_o(off_qix)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu qiw timeout case=%0d", cases); end

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
      if (wr_addr != APU_VGPU_TIW_ADDR || wr_len != 32'd4) order_bad <= 1'b1;
      if (wr_data[31:0] != APU_VGPU_TIW_REASON) data_bad <= 1'b1;
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
      if (rd_addr != APU_VGPU_TIW_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
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
    qux = '0;
    qux.valid = 1'b1;
    qux.used_idx = APU_VGPU_TUW_IDXV;
    qux.elem_id = APU_VGPU_TUW_ID;
    quw = '0;
    quw.valid = 1'b1;
    quw.elem_id = APU_VGPU_TUW_ID;
    quw.elem_len = VGPU_RESP_HDR_BYTES;
    quw.used_idx = APU_VGPU_TUW_IDXV;
    quw.elem_addr = APU_VGPU_TUW_ELEM;
    quw.idx_addr = APU_VGPU_TUW_IDX;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_qix == '0 &&
          off_cpl == '0);
  endtask

  task automatic qiw_step(input apu_vgpu_qiw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qiw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    qiw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qiw_req = 1'b0;
    while (!qiw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qiw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QIW_OK) begin
      check("notified", qiw.valid && qiw.reason == APU_VGPU_TIW_REASON &&
            qiw.used_idx == APU_VGPU_TUW_IDXV &&
            qiw.addr == APU_VGPU_TIW_ADDR &&
            qiw.addr != APU_VGPU_VIW_ADDR && irq == 1'b1);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_TIW_ADDR);
      irq_ack = 1'b1;
      @(posedge clk);
      @(negedge clk);
      irq_ack = 1'b0;
      check("ack lowers the pin", irq == 1'b0 && qiw.valid);
    end else if (name == "bad beat") begin
      check("one write failed", nwrite == n0 + 1 && !qiw.valid && irq == 1'b0);
    end else check("no write", nwrite == n0 && irq == 1'b0);
    @(negedge clk);
    check($sformatf("%s held", name), qiw_cpl_v);
    qiw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qiw_cpl_r = 1'b0;
    while (qiw_cpl_v) @(negedge clk);
  endtask

  task automatic qir_step(input apu_vgpu_qir_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!qir_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    qir_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qir_req = 1'b0;
    while (!qir_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qir_cpl.status == st);
    quiet();
    if (st == APU_VGPU_QIR_OK) begin
      check("echo", qir.valid && qir.reason == APU_VGPU_TIW_REASON &&
            qir.used_idx == APU_VGPU_TUW_IDXV &&
            qir.addr == APU_VGPU_TIW_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_TIW_ADDR);
    end else if (name == "bad read" || name == "zero reason") begin
      check("one read failed", nread == n0 + 1 && !qir.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), qir_cpl_v);
    qir_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qir_cpl_r = 1'b0;
    while (qir_cpl_v) @(negedge clk);
  endtask

  task automatic qix_step(input apu_vgpu_qix_status_e st, input string name);
    @(negedge clk);
    while (!qix_rdy) @(negedge clk);
    cases++;
    qix_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qix_req = 1'b0;
    while (!qix_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), qix_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), qix_cpl_v);
    qix_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    qix_cpl_r = 1'b0;
    while (qix_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    qiw_req = 1'b0;
    qir_req = 1'b0;
    qix_req = 1'b0;
    qiw_cpl_r = 1'b0;
    qir_cpl_r = 1'b0;
    qix_cpl_r = 1'b0;
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
    qux = '0;
    quw = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          qiw == '0 && qir == '0 && qix == '0 && irq == 1'b0);
    check("profiles keep the interrupt off",
          !ApuOff.QiwEn && !ApuOff.QirEn && !ApuOff.QixEn &&
          !ApuP1Transport.QiwEn && !ApuP1Transport.QirEn &&
          !ApuP1Transport.QixEn &&
          !ApuHarness.QiwEn && !ApuHarness.QirEn && !ApuHarness.QixEn &&
          !ApuSchedBoth.QiwEn && !ApuSchedBoth.QirEn && !ApuSchedBoth.QixEn &&
          !ApuBadVirglGrant.QiwEn && !ApuBadVirglGrant.QirEn &&
          !ApuBadVirglGrant.QixEn);
    cfg = ApuP1Transport;
    cfg.QiwEn = 1'b1;
    cfg.QirEn = 1'b1;
    cfg.QixEn = 1'b1;
    check("interrupt does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.QiwEn = 1'b1;
    cfg.QirEn = 1'b1;
    cfg.QixEn = 1'b1;
    check("interrupt does not legalize virgl", !apu_cfg_legal(cfg));
    check("known interrupt",
          APU_VGPU_TIW_ADDR != APU_VGPU_VIW_ADDR &&
          APU_VGPU_TIW_ADDR != APU_VGPU_TUW_ELEM &&
          APU_VGPU_TIW_REASON == 32'h1 &&
          APU_VGPU_TUW_IDXV != 16'd1);

    qiw_step(APU_VGPU_QIW_EMPTY, "write empty");
    qir_step(APU_VGPU_QIR_EMPTY, "read empty");
    qix_step(APU_VGPU_QIX_EMPTY, "keep empty");
    good_in();
    cancel = 1'b1;
    qiw_step(APU_VGPU_QIW_FAULT, "cancel");
    cancel = 1'b0;
    fail_wr = 1'b1;
    qiw_step(APU_VGPU_QIW_FAULT, "bad beat");
    qiw_step(APU_VGPU_QIW_OK, "notify");
    qiw_step(APU_VGPU_QIW_FAULT, "notify again");
    fail_rd = 1'b1;
    qir_step(APU_VGPU_QIR_FAULT, "bad read");
    bad_reason = 1'b1;
    qir_step(APU_VGPU_QIR_FAULT, "zero reason");
    qir_step(APU_VGPU_QIR_OK, "echo reason");
    qir_step(APU_VGPU_QIR_FAULT, "read again");
    qix_step(APU_VGPU_QIX_OK, "keep reason");
    check("keep reason", qix.valid && qix.reason == 32'h1 &&
          qix.used_idx == 16'd2 && qix.addr == APU_VGPU_TIW_ADDR &&
          qix.addr != APU_VGPU_VIW_ADDR);
    qix_step(APU_VGPU_QIX_FAULT, "keep again");
    check("reason stays", qix.reason == APU_VGPU_TIW_REASON);

    pulse_reset();
    check("reset clears", qiw == '0 && qir == '0 && qix == '0 && irq == 1'b0);
    qux = '0;
    quw = '0;
    qiw_step(APU_VGPU_QIW_EMPTY, "after reset");
    good_in();
    qiw_step(APU_VGPU_QIW_OK, "notify after reset");

    if (errors != 0) $fatal(1, "APU vgpu qiw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_qiw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
