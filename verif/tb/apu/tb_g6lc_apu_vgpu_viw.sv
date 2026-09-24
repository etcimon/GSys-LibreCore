// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_viw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cancel = 0, irq_ack = 0;
  apu_vgpu_gck_t gck;
  apu_vgpu_gpk_t gpk;
  apu_vgpu_ols_t ols;
  apu_vgpu_nxc_t nxc;
  apu_vgpu_cwr_t cwr;
  apu_vgpu_cxr_t cxr;
  logic viw_req = 0, viw_rdy, viw_cpl_v, viw_cpl_r = 0, irq;
  apu_vgpu_viw_cpl_t viw_cpl;
  apu_vgpu_viw_t viw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic vir_req = 0, vir_rdy, vir_cpl_v, vir_cpl_r = 0;
  apu_vgpu_vir_cpl_t vir_cpl;
  apu_vgpu_vir_t vir;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic vik_req = 0, vik_rdy, vik_cpl_v, vik_cpl_r = 0;
  apu_vgpu_vik_cpl_t vik_cpl, off_cpl;
  apu_vgpu_vik_t vik, off_vik;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, bad_reason = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int nwrite = 0, wr_base = 0, nread = 0, rd_base = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_VIW_REASON};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_viw #(.Enable(1'b1)) i_viw (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(irq_ack),
    .gck_i(gck), .gpk_i(gpk), .ols_i(ols), .nxc_i(nxc), .cwr_i(cwr), .cxr_i(cxr),
    .req_valid_i(viw_req), .req_ready_o(viw_rdy),
    .cpl_valid_o(viw_cpl_v), .cpl_ready_i(viw_cpl_r), .cpl_o(viw_cpl), .viw_o(viw),
    .irq_o(irq),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_vir #(.Enable(1'b1)) i_vir (
    .clk_i(clk), .rst_ni, .viw_i(viw), .gck_i(gck), .gpk_i(gpk), .ols_i(ols),
    .nxc_i(nxc),
    .req_valid_i(vir_req), .req_ready_o(vir_rdy),
    .cpl_valid_o(vir_cpl_v), .cpl_ready_i(vir_cpl_r), .cpl_o(vir_cpl), .vir_o(vir),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_vik #(.Enable(1'b1)) i_vik (
    .clk_i(clk), .rst_ni, .vir_i(vir), .viw_i(viw), .gck_i(gck), .gpk_i(gpk),
    .ols_i(ols),
    .req_valid_i(vik_req), .req_ready_o(vik_rdy),
    .cpl_valid_o(vik_cpl_v), .cpl_ready_i(vik_cpl_r), .cpl_o(vik_cpl), .vik_o(vik)
  );
  g6lc_apu_vgpu_vik_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .vir_i(vir), .viw_i(viw), .gck_i(gck), .gpk_i(gpk),
    .ols_i(ols),
    .req_valid_i(vik_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(vik_cpl_r), .cpl_o(off_cpl), .vik_o(off_vik)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu viw timeout case=%0d w=%0d", cases, nwrite); end

  function automatic logic [255:0] rd_pat;
    logic [255:0] beat;
    beat = Pat;
    beat[255:32] = 224'h1;
    if (bad_reason) beat[31:0] = 32'h2;
    rd_pat = beat;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
      order_bad <= 1'b0;
      data_bad <= 1'b0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      if (wr_addr != APU_VGPU_VIW_ADDR || wr_len != 32'd4) order_bad <= 1'b1;
      if (wr_data != Pat) data_bad <= 1'b1;
      seen <= wr_addr;
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
      if (rd_addr != APU_VGPU_VIW_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= rd_pat();
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
    gck = '0;
    gck.valid = 1'b1;
    gck.resp = VGPU_RESP_OK_NODATA;
    gck.fence = APU_VGPU_SCENE_FENCE;
    gck.elem_id = 32'd0;
    gck.elem_len = VGPU_RESP_HDR_BYTES;
    gck.used_idx = 16'd1;
    gpk = '0;
    gpk.valid = 1'b1;
    gpk.word = APU_VGPU_CLEAR_WORD;
    gpk.first = APU_VGPU_GPW_ADDR;
    gpk.last = APU_VGPU_GPW_TAIL;
    ols = '0;
    ols.valid = 1'b1;
    ols.count = 32'h0;
    ols.capset_id = 32'h0;
    ols.resp = VGPU_RESP_OK_NODATA;
    nxc = '0;
    nxc.valid = 1'b1;
    nxc.head = 16'd0;
    nxc.avail_idx = 16'd1;
    nxc.buf_len = APU_VGPU_SCENE_BYTES;
    nxc.buf_addr = APU_VGPU_EXEC_ADDR;
    nxc.rsp_addr = APU_VGPU_RSP_ADDR;
    cwr = '0;
    cwr.valid = 1'b1;
    cwr.word = APU_VGPU_CLEAR_WORD;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_vik == '0 &&
          off_cpl == '0);
  endtask

  task automatic viw_step(input apu_vgpu_viw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!viw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    wr_base = nwrite;
    viw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    viw_req = 1'b0;
    while (!viw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), viw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_VIW_OK) begin
      check("notified", viw.valid && viw.reason == APU_VGPU_VIW_REASON &&
            viw.used_idx == 16'd1 && irq == 1'b1);
      check("write count", nwrite == n0 + 1 && !order_bad && !data_bad &&
            seen == APU_VGPU_VIW_ADDR);
      irq_ack = 1'b1;
      @(posedge clk);
      @(negedge clk);
      irq_ack = 1'b0;
      check("ack lowers the pin", irq == 1'b0 && viw.valid &&
            viw.reason == APU_VGPU_VIW_REASON);
    end else if (name == "bad beat") begin
      check("one beat", nwrite == n0 + 1 && !viw.valid && irq == 1'b0);
    end else check("no write", nwrite == n0 && irq == 1'b0);
    @(negedge clk);
    check($sformatf("%s held", name), viw_cpl_v);
    viw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    viw_cpl_r = 1'b0;
    while (viw_cpl_v) @(negedge clk);
  endtask

  task automatic vir_step(input apu_vgpu_vir_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!vir_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    vir_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vir_req = 1'b0;
    while (!vir_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vir_cpl.status == st);
    quiet();
    if (st == APU_VGPU_VIR_OK) begin
      check("readback", vir.valid && vir.reason == viw.reason &&
            vir.used_idx == viw.used_idx);
      check("read count", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_VIW_ADDR);
    end else if (name == "bad beat" || name == "bad reason") begin
      check("one beat", nread == n0 + 1 && !vir.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), vir_cpl_v);
    vir_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vir_cpl_r = 1'b0;
    while (vir_cpl_v) @(negedge clk);
  endtask

  task automatic vik_step(input apu_vgpu_vik_status_e st, input string name);
    @(negedge clk);
    while (!vik_rdy) @(negedge clk);
    cases++;
    vik_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vik_req = 1'b0;
    while (!vik_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vik_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), vik_cpl_v);
    vik_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vik_cpl_r = 1'b0;
    while (vik_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    viw_req = 1'b0;
    vir_req = 1'b0;
    vik_req = 1'b0;
    viw_cpl_r = 1'b0;
    vir_cpl_r = 1'b0;
    vik_cpl_r = 1'b0;
    irq_ack = 1'b0;
    cancel = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    gck = '0;
    gpk = '0;
    ols = '0;
    nxc = '0;
    cwr = '0;
    cxr = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && irq == 1'b0 &&
          viw == '0 && vir == '0 && vik == '0);
    check("profiles keep the interrupt off",
          !ApuOff.ViwEn && !ApuOff.VirEn && !ApuOff.VikEn &&
          !ApuP1Transport.ViwEn && !ApuP1Transport.VirEn && !ApuP1Transport.VikEn &&
          !ApuHarness.ViwEn && !ApuHarness.VirEn && !ApuHarness.VikEn &&
          !ApuSchedBoth.ViwEn && !ApuSchedBoth.VirEn && !ApuSchedBoth.VikEn &&
          !ApuBadVirglGrant.ViwEn && !ApuBadVirglGrant.VirEn &&
          !ApuBadVirglGrant.VikEn);
    cfg = ApuP1Transport;
    cfg.ViwEn = 1'b1;
    cfg.VirEn = 1'b1;
    cfg.VikEn = 1'b1;
    check("interrupt does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.ViwEn = 1'b1;
    cfg.VirEn = 1'b1;
    cfg.VikEn = 1'b1;
    check("interrupt does not legalize virgl", !apu_cfg_legal(cfg));
    check("interrupt places",
          APU_VGPU_VIW_ADDR == 64'h8800E500 &&
          APU_VGPU_VIW_REASON == 32'h1 &&
          APU_VGPU_VIW_ADDR != APU_VGPU_GCW_IDX &&
          APU_VGPU_VIW_ADDR != APU_VGPU_GCW_ELEM &&
          APU_VGPU_VIW_ADDR != APU_VGPU_GPW_ADDR &&
          APU_VGPU_VIW_ADDR != APU_VGPU_SUN_ELEM &&
          APU_VGPU_VIW_ADDR != 64'h40001000);

    vir_step(APU_VGPU_VIR_EMPTY, "read empty");
    viw_step(APU_VGPU_VIW_EMPTY, "interrupt empty");
    vik_step(APU_VGPU_VIK_EMPTY, "keep empty");
    good_in();
    gpk = '0;
    viw_step(APU_VGPU_VIW_EMPTY, "window missing");
    good_in();
    cxr.height = 16'd64;
    viw_step(APU_VGPU_VIW_FAULT, "bad scissor");
    good_in();
    gck.used_idx = 16'd0;
    viw_step(APU_VGPU_VIW_FAULT, "bad index");
    good_in();
    cancel = 1'b1;
    viw_step(APU_VGPU_VIW_FAULT, "cancel");
    cancel = 1'b0;
    fail_wr = 1'b1;
    viw_step(APU_VGPU_VIW_FAULT, "bad beat");
    viw_step(APU_VGPU_VIW_OK, "notify");
    viw_step(APU_VGPU_VIW_FAULT, "notify again");
    check("notify stays", viw.valid && viw.reason == 32'h1 &&
          viw.used_idx == 16'd1 && irq == 1'b0);
    fail_rd = 1'b1;
    vir_step(APU_VGPU_VIR_FAULT, "bad beat");
    bad_reason = 1'b1;
    vir_step(APU_VGPU_VIR_FAULT, "bad reason");
    vir_step(APU_VGPU_VIR_OK, "read reason");
    vir_step(APU_VGPU_VIR_FAULT, "read reason again");
    check("read stays", vir.reason == 32'h1 && vir.used_idx == 16'd1);
    gpk.word = 32'h0;
    vik_step(APU_VGPU_VIK_FAULT, "keep bad word");
    check("keep rejected", !vik.valid);
    gpk.word = APU_VGPU_CLEAR_WORD;
    vik_step(APU_VGPU_VIK_OK, "keep reason");
    check("reason kept", vik.valid && vik.reason == 32'h1 && vik.used_idx == 16'd1);
    vik_step(APU_VGPU_VIK_FAULT, "keep again");
    check("keep stays", vik.reason == 32'h1 && vik.used_idx == viw.used_idx);

    pulse_reset();
    check("reset clears", viw == '0 && vir == '0 && vik == '0 && irq == 1'b0);
    zero_in();
    viw_step(APU_VGPU_VIW_EMPTY, "after reset");
    vir_step(APU_VGPU_VIR_EMPTY, "read after reset");
    vik_step(APU_VGPU_VIK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu viw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_viw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
