// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_uidx;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v, off_wrote, off_wr_v, off_rsp_rdy;
  logic [63:0] idx_addr, wr_addr, off_addr;
  logic [15:0] wr_data, off_data;
  logic wrote, wr_valid, wr_ready = 0, wr_rsp_ready;
  logic rsp_v = 0, rsp_ok = 0;
  logic [63:0] rsp_addr = '0;
  apu_vgpu_uidx_cpl_t cpl, off_cpl, snap;
  int errors = 0, checks = 0, cycles = 0, cases = 0, writes = 0;

  logic cancel = 0, ack = 0, u_v = 0, u_rdy, u_cplv, u_cplr = 0, pending, irq;
  logic [15:0] u_idx;
  logic [2:0] peek = 0;
  logic [31:0] peek_id, peek_len;
  apu_vgpu_used_req_t ureq;
  apu_vgpu_used_cpl_t ucpl, usnap;

  logic e_v = 0, e_rdy, e_cplv, e_cplr = 0, elem_wrote;
  logic [63:0] elem_addr, e_wr_addr, e_wr_data;
  logic e_wr_v, e_wr_ready = 0, e_rsp_rdy;
  logic e_rsp_v = 0, e_rsp_ok = 0;
  logic [63:0] e_rsp_addr = '0;
  apu_vgpu_uwr_cpl_t ecpl;

  localparam logic [63:0] ElemAddr = 64'h0000_0000_8800_3000;
  localparam logic [63:0] IdxAddr = 64'h0000_0000_8800_4002;

  g6lc_apu_vgpu_used #(.Enable(1'b1)) i_used (
    .clk_i(clk), .rst_ni, .cancel_i(cancel), .irq_ack_i(ack),
    .req_valid_i(u_v), .req_ready_o(u_rdy), .req_i(ureq),
    .cpl_valid_o(u_cplv), .cpl_ready_i(u_cplr), .cpl_o(ucpl),
    .idx_o(u_idx), .irq_o(irq), .pending_o(pending),
    .peek_i(peek), .peek_id_o(peek_id), .peek_len_o(peek_len)
  );
  g6lc_apu_vgpu_uwr #(.Enable(1'b1)) i_elem (
    .clk_i(clk), .rst_ni, .req_valid_i(e_v), .req_ready_o(e_rdy),
    .addr_i(elem_addr), .used_idx_i(u_idx), .elem_id_i(peek_id), .elem_len_i(peek_len),
    .cpl_valid_o(e_cplv), .cpl_ready_i(e_cplr), .cpl_o(ecpl), .wrote_o(elem_wrote),
    .wr_valid_o(e_wr_v), .wr_ready_i(e_wr_ready), .wr_addr_o(e_wr_addr), .wr_data_o(e_wr_data),
    .wr_rsp_valid_i(e_rsp_v), .wr_rsp_ready_o(e_rsp_rdy), .wr_rsp_ok_i(e_rsp_ok),
    .wr_rsp_addr_i(e_rsp_addr)
  );
  g6lc_apu_vgpu_uidx #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy),
    .addr_i(idx_addr), .used_idx_i(u_idx), .elem_wrote_i(elem_wrote),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .wrote_o(wrote),
    .wr_valid_o(wr_valid), .wr_ready_i(wr_ready), .wr_addr_o(wr_addr), .wr_data_o(wr_data),
    .wr_rsp_valid_i(rsp_v), .wr_rsp_ready_o(wr_rsp_ready), .wr_rsp_ok_i(rsp_ok),
    .wr_rsp_addr_i(rsp_addr)
  );
  g6lc_apu_vgpu_uidx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy),
    .addr_i(idx_addr), .used_idx_i(u_idx), .elem_wrote_i(elem_wrote),
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
  initial begin #200000; $fatal(1, "vgpu uidx timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_wrote !== 0 ||
        off_wr_v !== 0 || off_rsp_rdy !== 0 || off_addr !== 0 || off_data !== 0)
      $fatal(1, "disabled vgpu uidx active");
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

  task automatic store_elem;
    @(negedge clk);
    while (!e_rdy) @(negedge clk);
    elem_addr = ElemAddr;
    e_v = 1;
    @(posedge clk); @(negedge clk); e_v = 0;
    while (!e_wr_v) @(negedge clk);
    check("elem bus", e_wr_addr == ElemAddr && e_wr_data == {32'd24, 32'd4});
    e_wr_ready = 1;
    @(posedge clk); @(negedge clk); e_wr_ready = 0;
    if (e_rsp_rdy !== 1'b1) $fatal(1, "elem response not accepted");
    e_rsp_ok = 1;
    e_rsp_addr = ElemAddr;
    e_rsp_v = 1;
    @(posedge clk); @(negedge clk); e_rsp_v = 0;
    while (!e_cplv) @(negedge clk);
    check("elem ok", ecpl.status == APU_VGPU_UWR_OK && ecpl.elem_id == 32'd4 &&
          ecpl.elem_len == 32'd24);
    @(negedge clk);
    check("elem held", e_cplv && !e_rdy);
    e_cplr = 1;
    @(posedge clk); @(negedge clk); e_cplr = 0;
    while (e_cplv) @(negedge clk);
    check("elem wrote", elem_wrote == 1'b1);
  endtask

  task automatic uidx_step(
    input logic [63:0] addr,
    input logic do_write,
    input apu_vgpu_uidx_status_e st,
    input logic rsp_ok_v,
    input logic [63:0] rsp_addr_v,
    input logic [15:0] exp_idx,
    input string name
  );
    apu_vgpu_uidx_cpl_t seen;
    logic was_wrote;
    int was_writes;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    was_wrote = wrote;
    was_writes = writes;
    idx_addr = addr;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    if (do_write) begin
      while (!wr_valid) @(negedge clk);
      check($sformatf("%s bus", name), wr_addr == addr && wr_data == exp_idx);
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
    if (st == APU_VGPU_UIDX_OK)
      check($sformatf("%s echo", name), cpl.idx == exp_idx && cpl.addr == addr);
    else
      check($sformatf("%s quiet", name), cpl.idx == 16'h0 && cpl.addr == 64'h0);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == seen);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
    if (do_write)
      check($sformatf("%s one write", name), writes == was_writes + 1);
    if (st == APU_VGPU_UIDX_OK)
      check($sformatf("%s wrote", name), wrote == 1'b1);
    else
      check($sformatf("%s kept", name), wrote == was_wrote);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    e_v = 0;
    e_cplr = 0;
    u_v = 0;
    u_cplr = 0;
    wr_ready = 0;
    e_wr_ready = 0;
    rsp_v = 0;
    e_rsp_v = 0;
    cancel = 0;
    ack = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    idx_addr = '0;
    elem_addr = '0;
    ureq = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 &&
          wrote == 1'b0 && wr_valid == 1'b0 && elem_wrote == 1'b0);
    check("profiles keep uidx off",
          !ApuOff.UidxEn && !ApuP1Transport.UidxEn && !ApuHarness.UidxEn &&
          !ApuSchedBoth.UidxEn && !ApuBadVirglGrant.UidxEn);
    cfg = ApuP1Transport;
    cfg.UidxEn = 1'b1;
    check("uidx does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.UidxEn = 1'b1;
    check("uidx does not legalize virgl", !apu_cfg_legal(cfg));

    uidx_step(IdxAddr, 1'b0, APU_VGPU_UIDX_EMPTY, 1'b0, 64'h0, 16'h0, "empty");

    publish_used(32'd9, VGPU_RESP_HDR_BYTES, 1'b1, 1'b0, "cancel");
    check("cancel idx", u_idx == 16'd0 && elem_wrote == 1'b0);
    uidx_step(IdxAddr, 1'b0, APU_VGPU_UIDX_EMPTY, 1'b0, 64'h0, 16'h0, "prefix");

    publish_used(32'd4, VGPU_RESP_HDR_BYTES, 1'b0, 1'b1, "publish");
    peek = 3'd0;
    @(posedge clk);
    check("elem0", u_idx == 16'd1 && peek_id == 32'd4 && peek_len == VGPU_RESP_HDR_BYTES);
    @(negedge clk); ack = 1;
    @(posedge clk); @(negedge clk); ack = 0;
    uidx_step(IdxAddr, 1'b0, APU_VGPU_UIDX_FAULT, 1'b0, 64'h0, 16'd1, "before elem");

    store_elem();
    check("elem stays", elem_wrote == 1'b1 && u_idx == 16'd1);

    uidx_step(64'h0, 1'b0, APU_VGPU_UIDX_FAULT, 1'b0, 64'h0, 16'd1, "zero addr");
    uidx_step(64'h0000_0000_8800_4003, 1'b0, APU_VGPU_UIDX_FAULT, 1'b0, 64'h0, 16'd1, "odd");
    uidx_step(64'hffff_ffff_ffff_fffe, 1'b0, APU_VGPU_UIDX_FAULT, 1'b0, 64'h0, 16'd1, "wrap");
    uidx_step(IdxAddr, 1'b1, APU_VGPU_UIDX_BUS, 1'b0, IdxAddr, 16'd1, "bus err");
    check("bus keeps clear", wrote == 1'b0);
    uidx_step(IdxAddr, 1'b1, APU_VGPU_UIDX_BUS, 1'b1, IdxAddr + 64'h2, 16'd1, "bad rsp");
    check("bad rsp keeps clear", wrote == 1'b0);
    uidx_step(IdxAddr, 1'b1, APU_VGPU_UIDX_OK, 1'b1, IdxAddr, 16'd1, "store");
    check("stored idx", wrote == 1'b1 && snap.idx == 16'd1 && snap.addr == IdxAddr &&
          elem_wrote == 1'b1);
    uidx_step(IdxAddr + 64'h4, 1'b0, APU_VGPU_UIDX_FAULT, 1'b0, 64'h0, 16'd1, "second");
    check("second stays", wrote == 1'b1 && u_idx == 16'd1);

    pulse_reset();
    check("reset clears", wrote == 1'b0 && elem_wrote == 1'b0 && u_idx == 16'd0);
    uidx_step(IdxAddr, 1'b0, APU_VGPU_UIDX_EMPTY, 1'b0, 64'h0, 16'h0, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu uidx errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_uidx cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
