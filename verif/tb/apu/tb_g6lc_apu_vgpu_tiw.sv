// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_tiw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cancel = 0, irq_ack = 0, irq;
  apu_vgpu_tux_t tux;
  apu_vgpu_tuw_t tuw;
  logic tiw_req = 0, tiw_rdy, tiw_cpl_v, tiw_cpl_r = 0;
  apu_vgpu_tiw_cpl_t tiw_cpl;
  apu_vgpu_tiw_t tiw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic tir_req = 0, tir_rdy, tir_cpl_v, tir_cpl_r = 0;
  apu_vgpu_tir_cpl_t tir_cpl;
  apu_vgpu_tir_t tir;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic tix_req = 0, tix_rdy, tix_cpl_v, tix_cpl_r = 0;
  apu_vgpu_tix_cpl_t tix_cpl, off_cpl;
  apu_vgpu_tix_t tix, off_tix;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, bad_reason = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_TIW_REASON};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_tiw #(.Enable(1'b1)) i_tiw (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(irq_ack),
    .tux_i(tux), .tuw_i(tuw),
    .req_valid_i(tiw_req), .req_ready_o(tiw_rdy),
    .cpl_valid_o(tiw_cpl_v), .cpl_ready_i(tiw_cpl_r), .cpl_o(tiw_cpl), .tiw_o(tiw),
    .irq_o(irq),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_tir #(.Enable(1'b1)) i_tir (
    .clk_i(clk), .rst_ni, .tiw_i(tiw), .tux_i(tux),
    .req_valid_i(tir_req), .req_ready_o(tir_rdy),
    .cpl_valid_o(tir_cpl_v), .cpl_ready_i(tir_cpl_r), .cpl_o(tir_cpl), .tir_o(tir),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_tix #(.Enable(1'b1)) i_tix (
    .clk_i(clk), .rst_ni, .tir_i(tir), .tiw_i(tiw), .tux_i(tux),
    .req_valid_i(tix_req), .req_ready_o(tix_rdy),
    .cpl_valid_o(tix_cpl_v), .cpl_ready_i(tix_cpl_r), .cpl_o(tix_cpl), .tix_o(tix)
  );
  g6lc_apu_vgpu_tix_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .tir_i(tir), .tiw_i(tiw), .tux_i(tux),
    .req_valid_i(tix_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(tix_cpl_r), .cpl_o(off_cpl), .tix_o(off_tix)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu tiw timeout case=%0d", cases); end

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
    tux = '0;
    tux.valid = 1'b1;
    tux.used_idx = APU_VGPU_TUW_IDXV;
    tux.elem_id = APU_VGPU_TUW_ID;
    tuw = '0;
    tuw.valid = 1'b1;
    tuw.elem_id = APU_VGPU_TUW_ID;
    tuw.elem_len = VGPU_RESP_HDR_BYTES;
    tuw.used_idx = APU_VGPU_TUW_IDXV;
    tuw.elem_addr = APU_VGPU_TUW_ELEM;
    tuw.idx_addr = APU_VGPU_TUW_IDX;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_tix == '0 &&
          off_cpl == '0);
  endtask

  task automatic tiw_step(input apu_vgpu_tiw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!tiw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    tiw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tiw_req = 1'b0;
    while (!tiw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tiw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_TIW_OK) begin
      check("notified", tiw.valid && tiw.reason == APU_VGPU_TIW_REASON &&
            tiw.used_idx == APU_VGPU_TUW_IDXV &&
            tiw.addr == APU_VGPU_TIW_ADDR &&
            tiw.addr != APU_VGPU_VIW_ADDR && irq == 1'b1);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_TIW_ADDR);
      irq_ack = 1'b1;
      @(posedge clk);
      @(negedge clk);
      irq_ack = 1'b0;
      check("ack lowers the pin", irq == 1'b0 && tiw.valid);
    end else if (name == "bad beat") begin
      check("one write failed", nwrite == n0 + 1 && !tiw.valid && irq == 1'b0);
    end else check("no write", nwrite == n0 && irq == 1'b0);
    @(negedge clk);
    check($sformatf("%s held", name), tiw_cpl_v);
    tiw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tiw_cpl_r = 1'b0;
    while (tiw_cpl_v) @(negedge clk);
  endtask

  task automatic tir_step(input apu_vgpu_tir_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!tir_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    tir_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tir_req = 1'b0;
    while (!tir_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tir_cpl.status == st);
    quiet();
    if (st == APU_VGPU_TIR_OK) begin
      check("echo", tir.valid && tir.reason == APU_VGPU_TIW_REASON &&
            tir.used_idx == APU_VGPU_TUW_IDXV &&
            tir.addr == APU_VGPU_TIW_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_TIW_ADDR);
    end else if (name == "bad read" || name == "zero reason") begin
      check("one read failed", nread == n0 + 1 && !tir.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), tir_cpl_v);
    tir_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tir_cpl_r = 1'b0;
    while (tir_cpl_v) @(negedge clk);
  endtask

  task automatic tix_step(input apu_vgpu_tix_status_e st, input string name);
    @(negedge clk);
    while (!tix_rdy) @(negedge clk);
    cases++;
    tix_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tix_req = 1'b0;
    while (!tix_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tix_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), tix_cpl_v);
    tix_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tix_cpl_r = 1'b0;
    while (tix_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    tiw_req = 1'b0;
    tir_req = 1'b0;
    tix_req = 1'b0;
    tiw_cpl_r = 1'b0;
    tir_cpl_r = 1'b0;
    tix_cpl_r = 1'b0;
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
    tux = '0;
    tuw = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          tiw == '0 && tir == '0 && tix == '0 && irq == 1'b0);
    check("profiles keep the interrupt off",
          !ApuOff.TiwEn && !ApuOff.TirEn && !ApuOff.TixEn &&
          !ApuP1Transport.TiwEn && !ApuP1Transport.TirEn &&
          !ApuP1Transport.TixEn &&
          !ApuHarness.TiwEn && !ApuHarness.TirEn && !ApuHarness.TixEn &&
          !ApuSchedBoth.TiwEn && !ApuSchedBoth.TirEn && !ApuSchedBoth.TixEn &&
          !ApuBadVirglGrant.TiwEn && !ApuBadVirglGrant.TirEn &&
          !ApuBadVirglGrant.TixEn);
    cfg = ApuP1Transport;
    cfg.TiwEn = 1'b1;
    cfg.TirEn = 1'b1;
    cfg.TixEn = 1'b1;
    check("interrupt does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.TiwEn = 1'b1;
    cfg.TirEn = 1'b1;
    cfg.TixEn = 1'b1;
    check("interrupt does not legalize virgl", !apu_cfg_legal(cfg));
    check("known interrupt",
          APU_VGPU_TIW_ADDR != APU_VGPU_VIW_ADDR &&
          APU_VGPU_TIW_ADDR != APU_VGPU_TUW_ELEM &&
          APU_VGPU_TIW_REASON == 32'h1 &&
          APU_VGPU_TUW_IDXV != 16'd1);

    tiw_step(APU_VGPU_TIW_EMPTY, "write empty");
    tir_step(APU_VGPU_TIR_EMPTY, "read empty");
    tix_step(APU_VGPU_TIX_EMPTY, "keep empty");
    good_in();
    cancel = 1'b1;
    tiw_step(APU_VGPU_TIW_FAULT, "cancel");
    cancel = 1'b0;
    fail_wr = 1'b1;
    tiw_step(APU_VGPU_TIW_FAULT, "bad beat");
    tiw_step(APU_VGPU_TIW_OK, "notify");
    tiw_step(APU_VGPU_TIW_FAULT, "notify again");
    fail_rd = 1'b1;
    tir_step(APU_VGPU_TIR_FAULT, "bad read");
    bad_reason = 1'b1;
    tir_step(APU_VGPU_TIR_FAULT, "zero reason");
    tir_step(APU_VGPU_TIR_OK, "echo reason");
    tir_step(APU_VGPU_TIR_FAULT, "read again");
    tix_step(APU_VGPU_TIX_OK, "keep reason");
    check("keep reason", tix.valid && tix.reason == 32'h1 &&
          tix.used_idx == 16'd2 && tix.addr == APU_VGPU_TIW_ADDR &&
          tix.addr != APU_VGPU_VIW_ADDR);
    tix_step(APU_VGPU_TIX_FAULT, "keep again");
    check("reason stays", tix.reason == APU_VGPU_TIW_REASON);

    pulse_reset();
    check("reset clears", tiw == '0 && tir == '0 && tix == '0 && irq == 1'b0);
    tux = '0;
    tuw = '0;
    tiw_step(APU_VGPU_TIW_EMPTY, "after reset");
    good_in();
    tiw_step(APU_VGPU_TIW_OK, "notify after reset");

    if (errors != 0) $fatal(1, "APU vgpu tiw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_tiw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
