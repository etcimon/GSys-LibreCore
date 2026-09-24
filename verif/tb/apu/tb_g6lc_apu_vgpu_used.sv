// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_used;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0, cancel = 0, ack = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0, pending, irq;
  logic off_rdy, off_v, off_irq, off_pending;
  logic [15:0] idx;
  logic [2:0] peek = 0;
  logic [31:0] peek_id, peek_len;
  logic [319:0] cmd;
  apu_vgpu_used_req_t req;
  apu_vgpu_used_cpl_t cpl, off_cpl, snap;
  apu_vgpu_cpl_t vcpl;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  logic v_v = 0, v_rdy, v_cplv, v_cplr = 0;

  g6lc_apu_vgpu_cmd #(.Enable(1'b1)) i_cmd (
    .clk_i(clk), .rst_ni, .req_valid_i(v_v), .req_ready_o(v_rdy), .cmd_i(cmd),
    .cpl_valid_o(v_cplv), .cpl_ready_i(v_cplr), .cpl_o(vcpl),
    .slot0_o(), .slot1_o()
  );
  g6lc_apu_vgpu_used #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(ack),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl),
    .idx_o(idx), .irq_o(irq), .pending_o(pending),
    .peek_i(peek), .peek_id_o(peek_id), .peek_len_o(peek_len)
  );
  g6lc_apu_vgpu_used_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(ack),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .idx_o(), .irq_o(off_irq), .pending_o(off_pending),
    .peek_i(peek), .peek_id_o(), .peek_len_o()
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vgpu used timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_irq !== 0 || off_pending !== 0)
      $fatal(1, "disabled vgpu used active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic create_one;
    @(negedge clk);
    while (!v_rdy) @(negedge clk);
    cmd = {32'd2, 32'd4, VGPU_FORMAT_R8G8B8A8_UNORM, 32'd7, 32'h0, 32'd3,
           64'h1122_3344_5566_7788, VGPU_FLAG_FENCE, VGPU_CMD_RESOURCE_CREATE_2D};
    v_v = 1;
    @(posedge clk); @(negedge clk); v_v = 0;
    while (!v_cplv) @(negedge clk);
    check("create ok", vcpl.resp_type == VGPU_RESP_OK_NODATA);
    check("create fence", vcpl.flags == VGPU_FLAG_FENCE &&
          vcpl.fence_id == 64'h1122_3344_5566_7788);
    v_cplr = 1;
    @(posedge clk); @(negedge clk); v_cplr = 0;
  endtask

  task automatic publish(
    input logic [15:0] at,
    input logic [31:0] desc,
    input logic [31:0] len,
    input bit do_cancel,
    input bit expect_ok,
    input string name
  );
    logic [15:0] was;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    was = idx;
    req = '{idx: at, desc_id: desc, len: len};
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    if (expect_ok || do_cancel) begin
      check($sformatf("%s pending", name), pending && idx == was && irq == 1'b0);
      peek = was[2:0];
      if (do_cancel) cancel = 1;
      @(posedge clk);
      check($sformatf("%s prefix", name), peek_id == desc && peek_len == len);
    end
    while (!cpl_v) @(negedge clk);
    snap = cpl;
    check($sformatf("%s ok", name), cpl.ok == expect_ok);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == snap);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    cancel = 0;
    while (cpl_v) @(negedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    req = '0;
    cmd = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 && irq == 0);
    check("profiles keep used off", !ApuOff.UsedEn && !ApuHarness.UsedEn);
    cfg = ApuP1Transport;
    cfg.UsedEn = 1'b1;
    check("used does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.UsedEn = 1'b1;
    check("used does not legalize virgl", !apu_cfg_legal(cfg));

    create_one();
    publish(16'd0, 32'd4, VGPU_RESP_HDR_BYTES, 1'b0, 1'b1, "first");
    check("published idx", idx == 16'd1 && irq == 1'b1 && snap.desc_id == 32'd4 && snap.ok);
    peek = 3'd0;
    @(posedge clk);
    check("elem0", peek_id == 32'd4 && peek_len == VGPU_RESP_HDR_BYTES);
    @(negedge clk); ack = 1;
    @(posedge clk); @(negedge clk); ack = 0;
    check("ack drops irq", irq == 1'b0 && idx == 16'd1);

    publish(16'd1, 32'd5, VGPU_RESP_HDR_BYTES, 1'b0, 1'b1, "second");
    check("second idx", idx == 16'd2 && irq == 1'b1);
    @(negedge clk); ack = 1;
    @(posedge clk); @(negedge clk); ack = 0;

    publish(16'd0, 32'd9, VGPU_RESP_HDR_BYTES, 1'b0, 1'b0, "stale idx");
    check("stale keeps idx", idx == 16'd2 && irq == 1'b0);

    publish(16'd2, 32'd6, 32'd8, 1'b0, 1'b0, "bad len");
    check("bad len keeps idx", idx == 16'd2 && irq == 1'b0);

    publish(16'd2, 32'd6, VGPU_RESP_HDR_BYTES, 1'b1, 1'b0, "cancel");
    check("cancel keeps idx", idx == 16'd2 && irq == 1'b0);
    peek = 3'd2;
    @(posedge clk);
    check("unpublished prefix", peek_id == 32'd6 && peek_len == VGPU_RESP_HDR_BYTES);
    peek = 3'd0;
    @(posedge clk);
    check("elem0 survives", peek_id == 32'd4);

    if (errors != 0) $fatal(1, "APU vgpu used errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_used cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
