// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_uwr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v, off_wrote, off_wr_v, off_rsp_rdy;
  logic [63:0] guest_addr, wr_addr, off_addr, wr_data, off_data;
  logic wrote, wr_valid, wr_ready = 0, wr_rsp_ready;
  logic rsp_v = 0, rsp_ok = 0;
  logic [63:0] rsp_addr = '0;
  apu_vgpu_uwr_cpl_t cpl, off_cpl, snap;
  int errors = 0, checks = 0, cycles = 0, cases = 0, writes = 0;

  logic cancel = 0, ack = 0, u_v = 0, u_rdy, u_cplv, u_cplr = 0, pending, irq;
  logic [15:0] u_idx;
  logic [2:0] peek = 0;
  logic [31:0] peek_id, peek_len;
  apu_vgpu_used_req_t ureq;
  apu_vgpu_used_cpl_t ucpl, usnap;

  localparam logic [63:0] GuestAddr = 64'h0000_0000_8800_3000;

  g6lc_apu_vgpu_used #(.Enable(1'b1)) i_used (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(ack),
    .req_valid_i(u_v), .req_ready_o(u_rdy), .req_i(ureq),
    .cpl_valid_o(u_cplv), .cpl_ready_i(u_cplr), .cpl_o(ucpl),
    .idx_o(u_idx), .irq_o(irq), .pending_o(pending),
    .peek_i(peek), .peek_id_o(peek_id), .peek_len_o(peek_len)
  );
  g6lc_apu_vgpu_uwr #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy),
    .addr_i(guest_addr), .used_idx_i(u_idx), .elem_id_i(peek_id), .elem_len_i(peek_len),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .wrote_o(wrote),
    .wr_valid_o(wr_valid), .wr_ready_i(wr_ready), .wr_addr_o(wr_addr), .wr_data_o(wr_data),
    .wr_rsp_valid_i(rsp_v), .wr_rsp_ready_o(wr_rsp_ready), .wr_rsp_ok_i(rsp_ok),
    .wr_rsp_addr_i(rsp_addr)
  );
  g6lc_apu_vgpu_uwr_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy),
    .addr_i(guest_addr), .used_idx_i(u_idx), .elem_id_i(peek_id), .elem_len_i(peek_len),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .wrote_o(off_wrote),
    .wr_valid_o(off_wr_v), .wr_ready_i(wr_ready), .wr_addr_o(off_addr), .wr_data_o(off_data),
    .wr_rsp_valid_i(rsp_v), .wr_rsp_ready_o(off_rsp_rdy), .wr_rsp_ok_i(rsp_ok),
    .wr_rsp_addr_i(rsp_addr)
  );

  always #5 clk = ~clk;
  always @(posedge clk) begin
    cycles++;
    if (rst_ni && wr_valid && wr_ready) writes++;
  end
  initial begin #200000; $fatal(1, "vgpu uwr timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_wrote !== 0 ||
        off_wr_v !== 0 || off_rsp_rdy !== 0 || off_addr !== 0 || off_data !== 0)
      $fatal(1, "disabled vgpu uwr active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic publish_used(
    input logic [31:0] desc,
    input logic [31:0] len,
    input logic do_cancel,
    input logic want_ok,
    input string name
  );
    logic [15:0] was;
    @(negedge clk);
    while (!u_rdy) @(negedge clk);
    was = u_idx;
    ureq = '{idx: was, desc_id: desc, len: len};
    u_v = 1;
    @(posedge clk); @(negedge clk); u_v = 0;
    if (want_ok || do_cancel) begin
      check($sformatf("%s pending", name), pending && u_idx == was && irq == 1'b0);
      peek = was[2:0];
      if (do_cancel) cancel = 1;
      @(posedge clk);
      check($sformatf("%s prefix", name), peek_id == desc && peek_len == len);
    end
    while (!u_cplv) @(negedge clk);
    usnap = ucpl;
    check($sformatf("%s ok", name), ucpl.ok == want_ok);
    @(negedge clk);
    check($sformatf("%s held", name), u_cplv && !u_rdy && ucpl == usnap);
    u_cplr = 1;
    @(posedge clk); @(negedge clk); u_cplr = 0;
    cancel = 0;
    while (u_cplv) @(negedge clk);
  endtask

  task automatic uwr_step(
    input logic [63:0] addr,
    input logic do_write,
    input apu_vgpu_uwr_status_e st,
    input logic rsp_ok_v,
    input logic [63:0] rsp_addr_v,
    input logic [31:0] exp_id,
    input logic [31:0] exp_len,
    input string name
  );
    apu_vgpu_uwr_cpl_t seen;
    logic was_wrote;
    int was_writes;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    was_wrote = wrote;
    was_writes = writes;
    guest_addr = addr;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    if (do_write) begin
      while (!wr_valid) @(negedge clk);
      check($sformatf("%s bus", name), wr_addr == addr && wr_data == {exp_len, exp_id});
      wr_ready = 1;
      @(posedge clk); @(negedge clk); wr_ready = 0;
      if (wr_rsp_ready !== 1'b1) $fatal(1, "%s response not accepted", name);
      rsp_ok = rsp_ok_v;
      rsp_addr = rsp_addr_v;
      rsp_v = 1;
      @(posedge clk); @(negedge clk); rsp_v = 0;
    end
    while (!cpl_v) @(negedge clk);
    if (!do_write)
      check($sformatf("%s no write", name), wr_valid == 1'b0 && writes == was_writes);
    seen = cpl;
    snap = cpl;
    check($sformatf("%s status", name), cpl.status == st);
    if (st == APU_VGPU_UWR_OK) begin
      check($sformatf("%s echo", name), cpl.elem_id == exp_id && cpl.elem_len == exp_len &&
            cpl.addr == addr);
    end else begin
      check($sformatf("%s quiet", name), cpl.elem_id == 32'h0 && cpl.elem_len == 32'h0 &&
            cpl.addr == 64'h0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == seen);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
    if (do_write)
      check($sformatf("%s one write", name), writes == was_writes + 1);
    if (st == APU_VGPU_UWR_OK)
      check($sformatf("%s wrote", name), wrote == 1'b1);
    else
      check($sformatf("%s kept", name), wrote == was_wrote);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    u_v = 0;
    u_cplr = 0;
    wr_ready = 0;
    rsp_v = 0;
    cancel = 0;
    ack = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    guest_addr = '0;
    ureq = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 &&
          wrote == 1'b0 && wr_valid == 1'b0);
    check("profiles keep uwr off",
          !ApuOff.UwrEn && !ApuP1Transport.UwrEn && !ApuHarness.UwrEn &&
          !ApuSchedBoth.UwrEn && !ApuBadVirglGrant.UwrEn);
    cfg = ApuP1Transport;
    cfg.UwrEn = 1'b1;
    check("uwr does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.UwrEn = 1'b1;
    check("uwr does not legalize virgl", !apu_cfg_legal(cfg));

    uwr_step(GuestAddr, 1'b0, APU_VGPU_UWR_EMPTY, 1'b0, 64'h0, 32'h0, 32'h0, "empty");

    publish_used(32'd9, VGPU_RESP_HDR_BYTES, 1'b1, 1'b0, "cancel");
    check("cancel idx", u_idx == 16'd0 && irq == 1'b0 && peek_id == 32'd9);
    uwr_step(GuestAddr, 1'b0, APU_VGPU_UWR_EMPTY, 1'b0, 64'h0, 32'd9, 32'd24, "prefix");

    publish_used(32'd4, VGPU_RESP_HDR_BYTES, 1'b0, 1'b1, "publish");
    check("published", u_idx == 16'd1 && irq == 1'b1 && usnap.desc_id == 32'd4 &&
          usnap.len == VGPU_RESP_HDR_BYTES);
    peek = 3'd0;
    @(posedge clk);
    check("elem0", peek_id == 32'd4 && peek_len == VGPU_RESP_HDR_BYTES);
    @(negedge clk); ack = 1;
    @(posedge clk); @(negedge clk); ack = 0;
    check("ack drops irq", irq == 1'b0 && u_idx == 16'd1);

    uwr_step(64'h0, 1'b0, APU_VGPU_UWR_FAULT, 1'b0, 64'h0, 32'd4, 32'd24, "zero addr");
    uwr_step(64'h0000_0000_8800_3004, 1'b0, APU_VGPU_UWR_FAULT, 1'b0, 64'h0,
             32'd4, 32'd24, "align");
    uwr_step(64'hffff_ffff_ffff_fff8, 1'b0, APU_VGPU_UWR_FAULT, 1'b0, 64'h0,
             32'd4, 32'd24, "wrap");
    uwr_step(GuestAddr, 1'b1, APU_VGPU_UWR_BUS, 1'b0, GuestAddr, 32'd4, 32'd24, "bus err");
    check("bus keeps clear", wrote == 1'b0);
    uwr_step(GuestAddr, 1'b1, APU_VGPU_UWR_BUS, 1'b1, GuestAddr + 64'h8, 32'd4, 32'd24,
             "bad rsp");
    check("bad rsp keeps clear", wrote == 1'b0);
    uwr_step(GuestAddr, 1'b1, APU_VGPU_UWR_OK, 1'b1, GuestAddr, 32'd4, 32'd24, "store");
    check("stored once", wrote == 1'b1 && snap.elem_id == 32'd4 &&
          snap.elem_len == VGPU_RESP_HDR_BYTES && snap.addr == GuestAddr);
    uwr_step(GuestAddr + 64'h10, 1'b0, APU_VGPU_UWR_FAULT, 1'b0, 64'h0, 32'd4, 32'd24,
             "second");
    check("second stays", wrote == 1'b1 && u_idx == 16'd1);

    pulse_reset();
    check("reset clears", wrote == 1'b0 && u_idx == 16'd0);
    uwr_step(GuestAddr, 1'b0, APU_VGPU_UWR_EMPTY, 1'b0, 64'h0, 32'h0, 32'h0, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu uwr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_uwr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
