// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_riw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cancel = 0, irq_ack = 0, irq;
  apu_vgpu_rux_t rux;
  apu_vgpu_ruw_t ruw;
  logic riw_req = 0, riw_rdy, riw_cpl_v, riw_cpl_r = 0;
  apu_vgpu_riw_cpl_t riw_cpl;
  apu_vgpu_riw_t riw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic rir_req = 0, rir_rdy, rir_cpl_v, rir_cpl_r = 0;
  apu_vgpu_rir_cpl_t rir_cpl;
  apu_vgpu_rir_t rir;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic rix_req = 0, rix_rdy, rix_cpl_v, rix_cpl_r = 0;
  apu_vgpu_rix_cpl_t rix_cpl, off_cpl;
  apu_vgpu_rix_t rix, off_rix;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, bad_reason = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_TIW_REASON};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_riw #(.Enable(1'b1)) i_riw (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(irq_ack),
    .rux_i(rux), .ruw_i(ruw),
    .req_valid_i(riw_req), .req_ready_o(riw_rdy),
    .cpl_valid_o(riw_cpl_v), .cpl_ready_i(riw_cpl_r), .cpl_o(riw_cpl), .riw_o(riw),
    .irq_o(irq),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_rir #(.Enable(1'b1)) i_rir (
    .clk_i(clk), .rst_ni, .riw_i(riw), .rux_i(rux),
    .req_valid_i(rir_req), .req_ready_o(rir_rdy),
    .cpl_valid_o(rir_cpl_v), .cpl_ready_i(rir_cpl_r), .cpl_o(rir_cpl), .rir_o(rir),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rix #(.Enable(1'b1)) i_rix (
    .clk_i(clk), .rst_ni, .rir_i(rir), .riw_i(riw), .rux_i(rux),
    .req_valid_i(rix_req), .req_ready_o(rix_rdy),
    .cpl_valid_o(rix_cpl_v), .cpl_ready_i(rix_cpl_r), .cpl_o(rix_cpl), .rix_o(rix)
  );
  g6lc_apu_vgpu_rix_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rir_i(rir), .riw_i(riw), .rux_i(rux),
    .req_valid_i(rix_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rix_cpl_r), .cpl_o(off_cpl), .rix_o(off_rix)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu riw timeout case=%0d", cases); end

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
    rux = '0;
    rux.valid = 1'b1;
    rux.used_idx = APU_VGPU_TUW_IDXV;
    rux.elem_id = APU_VGPU_TUW_ID;
    ruw = '0;
    ruw.valid = 1'b1;
    ruw.elem_id = APU_VGPU_TUW_ID;
    ruw.elem_len = VGPU_RESP_HDR_BYTES;
    ruw.used_idx = APU_VGPU_TUW_IDXV;
    ruw.elem_addr = APU_VGPU_TUW_ELEM;
    ruw.idx_addr = APU_VGPU_TUW_IDX;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rix == '0 &&
          off_cpl == '0);
  endtask

  task automatic riw_step(input apu_vgpu_riw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!riw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    riw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    riw_req = 1'b0;
    while (!riw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), riw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RIW_OK) begin
      check("notified", riw.valid && riw.reason == APU_VGPU_TIW_REASON &&
            riw.used_idx == APU_VGPU_TUW_IDXV &&
            riw.addr == APU_VGPU_TIW_ADDR &&
            riw.addr != APU_VGPU_VIW_ADDR && irq == 1'b1);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_TIW_ADDR);
      irq_ack = 1'b1;
      @(posedge clk);
      @(negedge clk);
      irq_ack = 1'b0;
      check("ack lowers the pin", irq == 1'b0 && riw.valid);
    end else if (name == "bad beat") begin
      check("one write failed", nwrite == n0 + 1 && !riw.valid && irq == 1'b0);
    end else check("no write", nwrite == n0 && irq == 1'b0);
    @(negedge clk);
    check($sformatf("%s held", name), riw_cpl_v);
    riw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    riw_cpl_r = 1'b0;
    while (riw_cpl_v) @(negedge clk);
  endtask

  task automatic rir_step(input apu_vgpu_rir_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rir_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rir_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rir_req = 1'b0;
    while (!rir_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rir_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RIR_OK) begin
      check("echo", rir.valid && rir.reason == APU_VGPU_TIW_REASON &&
            rir.used_idx == APU_VGPU_TUW_IDXV &&
            rir.addr == APU_VGPU_TIW_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_TIW_ADDR);
    end else if (name == "bad read" || name == "zero reason") begin
      check("one read failed", nread == n0 + 1 && !rir.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rir_cpl_v);
    rir_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rir_cpl_r = 1'b0;
    while (rir_cpl_v) @(negedge clk);
  endtask

  task automatic rix_step(input apu_vgpu_rix_status_e st, input string name);
    @(negedge clk);
    while (!rix_rdy) @(negedge clk);
    cases++;
    rix_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rix_req = 1'b0;
    while (!rix_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rix_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rix_cpl_v);
    rix_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rix_cpl_r = 1'b0;
    while (rix_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    riw_req = 1'b0;
    rir_req = 1'b0;
    rix_req = 1'b0;
    riw_cpl_r = 1'b0;
    rir_cpl_r = 1'b0;
    rix_cpl_r = 1'b0;
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
    rux = '0;
    ruw = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          riw == '0 && rir == '0 && rix == '0 && irq == 1'b0);
    check("profiles keep the interrupt off",
          !ApuOff.RiwEn && !ApuOff.RirEn && !ApuOff.RixEn &&
          !ApuP1Transport.RiwEn && !ApuP1Transport.RirEn &&
          !ApuP1Transport.RixEn &&
          !ApuHarness.RiwEn && !ApuHarness.RirEn && !ApuHarness.RixEn &&
          !ApuSchedBoth.RiwEn && !ApuSchedBoth.RirEn && !ApuSchedBoth.RixEn &&
          !ApuBadVirglGrant.RiwEn && !ApuBadVirglGrant.RirEn &&
          !ApuBadVirglGrant.RixEn);
    cfg = ApuP1Transport;
    cfg.RiwEn = 1'b1;
    cfg.RirEn = 1'b1;
    cfg.RixEn = 1'b1;
    check("interrupt does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RiwEn = 1'b1;
    cfg.RirEn = 1'b1;
    cfg.RixEn = 1'b1;
    check("interrupt does not legalize virgl", !apu_cfg_legal(cfg));
    check("known interrupt",
          APU_VGPU_TIW_ADDR != APU_VGPU_VIW_ADDR &&
          APU_VGPU_TIW_ADDR != APU_VGPU_TUW_ELEM &&
          APU_VGPU_TIW_REASON == 32'h1 &&
          APU_VGPU_TUW_IDXV != 16'd1);

    riw_step(APU_VGPU_RIW_EMPTY, "write empty");
    rir_step(APU_VGPU_RIR_EMPTY, "read empty");
    rix_step(APU_VGPU_RIX_EMPTY, "keep empty");
    good_in();
    cancel = 1'b1;
    riw_step(APU_VGPU_RIW_FAULT, "cancel");
    cancel = 1'b0;
    fail_wr = 1'b1;
    riw_step(APU_VGPU_RIW_FAULT, "bad beat");
    riw_step(APU_VGPU_RIW_OK, "notify");
    riw_step(APU_VGPU_RIW_FAULT, "notify again");
    fail_rd = 1'b1;
    rir_step(APU_VGPU_RIR_FAULT, "bad read");
    bad_reason = 1'b1;
    rir_step(APU_VGPU_RIR_FAULT, "zero reason");
    rir_step(APU_VGPU_RIR_OK, "echo reason");
    rir_step(APU_VGPU_RIR_FAULT, "read again");
    rix_step(APU_VGPU_RIX_OK, "keep reason");
    check("keep reason", rix.valid && rix.reason == 32'h1 &&
          rix.used_idx == 16'd2 && rix.addr == APU_VGPU_TIW_ADDR &&
          rix.addr != APU_VGPU_VIW_ADDR);
    rix_step(APU_VGPU_RIX_FAULT, "keep again");
    check("reason stays", rix.reason == APU_VGPU_TIW_REASON);

    pulse_reset();
    check("reset clears", riw == '0 && rir == '0 && rix == '0 && irq == 1'b0);
    rux = '0;
    ruw = '0;
    riw_step(APU_VGPU_RIW_EMPTY, "after reset");
    good_in();
    riw_step(APU_VGPU_RIW_OK, "notify after reset");

    if (errors != 0) $fatal(1, "APU vgpu riw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_riw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
