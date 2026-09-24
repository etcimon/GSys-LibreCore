// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_sunw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_sun_t sun;
  apu_vgpu_suw_t suw, suw_force, suw_i_bus;
  logic use_force = 0;
  logic suw_req = 0, suw_rdy, suw_cpl_v, suw_cpl_r = 0;
  apu_vgpu_suw_cpl_t suw_cpl;
  logic suw_wr, suw_wrr = 0, suw_rsp_v = 0, suw_rsp_ok = 0, suw_rsp_rdy;
  logic [63:0] suw_addr, suw_data, suw_rsp_addr;
  logic sux_req = 0, sux_rdy, sux_cpl_v, sux_cpl_r = 0;
  apu_vgpu_sux_cpl_t sux_cpl, off_cpl;
  apu_vgpu_sux_t sux, off_sux;
  logic sux_wr, sux_wrr = 0, sux_rsp_v = 0, sux_rsp_ok = 0, sux_rsp_rdy;
  logic off_rdy, off_v, off_wr, off_rsp_rdy;
  logic [63:0] sux_addr, off_addr, sux_rsp_addr;
  logic [15:0] sux_data, off_data;
  int errors = 0, checks = 0, cycles = 0, cases = 0, writes = 0;

  localparam logic [63:0] ElemBits = {VGPU_RESP_HDR_BYTES, 32'd0};

  assign suw_i_bus = use_force ? suw_force : suw;

  g6lc_apu_vgpu_suw #(.Enable(1'b1)) i_suw (
    .clk_i(clk), .rst_ni, .sun_i(sun),
    .req_valid_i(suw_req), .req_ready_o(suw_rdy),
    .cpl_valid_o(suw_cpl_v), .cpl_ready_i(suw_cpl_r), .cpl_o(suw_cpl), .suw_o(suw),
    .wr_valid_o(suw_wr), .wr_ready_i(suw_wrr), .wr_addr_o(suw_addr), .wr_data_o(suw_data),
    .wr_rsp_valid_i(suw_rsp_v), .wr_rsp_ready_o(suw_rsp_rdy), .wr_rsp_ok_i(suw_rsp_ok),
    .wr_rsp_addr_i(suw_rsp_addr)
  );
  g6lc_apu_vgpu_sux #(.Enable(1'b1)) i_sux (
    .clk_i(clk), .rst_ni, .sun_i(sun), .suw_i(suw_i_bus),
    .req_valid_i(sux_req), .req_ready_o(sux_rdy),
    .cpl_valid_o(sux_cpl_v), .cpl_ready_i(sux_cpl_r), .cpl_o(sux_cpl), .sux_o(sux),
    .wr_valid_o(sux_wr), .wr_ready_i(sux_wrr), .wr_addr_o(sux_addr), .wr_data_o(sux_data),
    .wr_rsp_valid_i(sux_rsp_v), .wr_rsp_ready_o(sux_rsp_rdy), .wr_rsp_ok_i(sux_rsp_ok),
    .wr_rsp_addr_i(sux_rsp_addr)
  );
  g6lc_apu_vgpu_sux_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .sun_i(sun), .suw_i(suw_i_bus),
    .req_valid_i(sux_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(sux_cpl_r), .cpl_o(off_cpl), .sux_o(off_sux),
    .wr_valid_o(off_wr), .wr_ready_i(sux_wrr), .wr_addr_o(off_addr), .wr_data_o(off_data),
    .wr_rsp_valid_i(sux_rsp_v), .wr_rsp_ready_o(off_rsp_rdy), .wr_rsp_ok_i(sux_rsp_ok),
    .wr_rsp_addr_i(sux_rsp_addr)
  );

  always #5 clk = ~clk;
  always @(posedge clk) begin
    cycles++;
    if (rst_ni && ((suw_wr && suw_wrr) || (sux_wr && sux_wrr))) writes++;
  end
  initial begin #1000000; $fatal(1, "APU vgpu sunw timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_sun;
    sun = '0;
    sun.valid = 1'b1;
    sun.idx = 16'd1;
    sun.desc_id = 32'd0;
    sun.len = VGPU_RESP_HDR_BYTES;
  endtask

  task automatic suw_step(
    input apu_vgpu_suw_status_e st,
    input logic do_write,
    input logic bus_bad,
    input string name
  );
    @(negedge clk);
    while (!suw_rdy) @(negedge clk);
    cases++;
    suw_req = 1;
    @(posedge clk); @(negedge clk); suw_req = 0;
    if (do_write) begin
      while (!suw_wr) @(negedge clk);
      check($sformatf("%s addr", name), suw_addr == APU_VGPU_SUN_ELEM && suw_data == ElemBits);
      check($sformatf("%s not create2d", name), suw_addr != 64'h0000_0000_8800_3000);
      suw_wrr = 1;
      @(posedge clk); @(negedge clk); suw_wrr = 0;
      suw_rsp_ok = !bus_bad;
      suw_rsp_addr = APU_VGPU_SUN_ELEM;
      suw_rsp_v = 1;
      @(posedge clk); @(negedge clk); suw_rsp_v = 0;
    end
    while (!suw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), suw_cpl.status == st);
    if (st == APU_VGPU_SUW_OK)
      check($sformatf("%s echo", name), suw_cpl.elem_id == 32'd0 &&
            suw_cpl.elem_len == VGPU_RESP_HDR_BYTES && suw_cpl.addr == APU_VGPU_SUN_ELEM);
    if (!do_write)
      check($sformatf("%s no store", name), suw_wr == 1'b0);
    @(negedge clk);
    check($sformatf("%s held", name), suw_cpl_v);
    suw_cpl_r = 1;
    @(posedge clk); @(negedge clk); suw_cpl_r = 0;
    while (suw_cpl_v) @(negedge clk);
  endtask

  task automatic sux_step(
    input apu_vgpu_sux_status_e st,
    input logic do_write,
    input logic bus_bad,
    input string name
  );
    @(negedge clk);
    while (!sux_rdy) @(negedge clk);
    cases++;
    sux_req = 1;
    @(posedge clk); @(negedge clk); sux_req = 0;
    if (do_write) begin
      while (!sux_wr) @(negedge clk);
      check($sformatf("%s addr", name), sux_addr == APU_VGPU_SUN_IDX && sux_data == 16'd1);
      check($sformatf("%s not create2d", name), sux_addr != 64'h0000_0000_8800_4002);
      check($sformatf("%s off quiet", name), off_rdy == 0 && off_v == 0 && off_wr == 0 && off_sux == '0);
      sux_wrr = 1;
      @(posedge clk); @(negedge clk); sux_wrr = 0;
      sux_rsp_ok = !bus_bad;
      sux_rsp_addr = APU_VGPU_SUN_IDX;
      sux_rsp_v = 1;
      @(posedge clk); @(negedge clk); sux_rsp_v = 0;
    end
    while (!sux_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sux_cpl.status == st);
    if (st == APU_VGPU_SUX_OK)
      check($sformatf("%s echo", name), sux_cpl.idx == 16'd1 && sux_cpl.addr == APU_VGPU_SUN_IDX);
    if (!do_write)
      check($sformatf("%s no store", name), sux_wr == 1'b0);
    @(negedge clk);
    check($sformatf("%s held", name), sux_cpl_v);
    sux_cpl_r = 1;
    @(posedge clk); @(negedge clk); sux_cpl_r = 0;
    while (sux_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    suw_req = 0;
    sux_req = 0;
    suw_cpl_r = 0;
    sux_cpl_r = 0;
    suw_wrr = 0;
    sux_wrr = 0;
    suw_rsp_v = 0;
    sux_rsp_v = 0;
    use_force = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    sun = '0;
    suw_force = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && off_wr == 0 && suw == '0 && sux == '0);
    check("profiles keep sunw off",
          !ApuOff.SuwEn && !ApuOff.SuxEn &&
          !ApuP1Transport.SuwEn && !ApuP1Transport.SuxEn &&
          !ApuHarness.SuwEn && !ApuHarness.SuxEn &&
          !ApuSchedBoth.SuwEn && !ApuSchedBoth.SuxEn &&
          !ApuBadVirglGrant.SuwEn && !ApuBadVirglGrant.SuxEn);
    cfg = ApuP1Transport;
    cfg.SuwEn = 1'b1;
    cfg.SuxEn = 1'b1;
    check("sunw does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.SuwEn = 1'b1;
    cfg.SuxEn = 1'b1;
    check("sunw does not legalize virgl", !apu_cfg_legal(cfg));

    suw_step(APU_VGPU_SUW_EMPTY, 1'b0, 1'b0, "empty");
    sux_step(APU_VGPU_SUX_EMPTY, 1'b0, 1'b0, "idx early");
    sun.valid = 1'b1;
    sun.idx = 16'd0;
    sun.desc_id = 32'd0;
    sun.len = VGPU_RESP_HDR_BYTES;
    suw_step(APU_VGPU_SUW_FAULT, 1'b0, 1'b0, "idx0");
    check("idx0 keeps", !suw.wrote);
    good_sun();
    suw_step(APU_VGPU_SUW_BUS, 1'b1, 1'b1, "elem bus");
    check("bus keeps", !suw.wrote);
    suw_step(APU_VGPU_SUW_OK, 1'b1, 1'b0, "elem");
    check("elem record", suw.wrote && suw.addr == APU_VGPU_SUN_ELEM);
    suw_step(APU_VGPU_SUW_FAULT, 1'b0, 1'b0, "elem again");
    check("elem kept", suw.wrote && suw.addr == APU_VGPU_SUN_ELEM);

    pulse_reset();
    check("reset clears", suw == '0 && sux == '0);
    good_sun();
    suw_step(APU_VGPU_SUW_OK, 1'b1, 1'b0, "elem2");
    suw_force = '0;
    suw_force.wrote = 1'b1;
    suw_force.addr = 64'h0000_0000_8800_3000;
    use_force = 1'b1;
    sux_step(APU_VGPU_SUX_FAULT, 1'b0, 1'b0, "idx other");
    check("other keeps", !sux.wrote);
    use_force = 1'b0;
    sux_step(APU_VGPU_SUX_BUS, 1'b1, 1'b1, "idx bus");
    check("idx bus keeps", !sux.wrote);
    sux_step(APU_VGPU_SUX_OK, 1'b1, 1'b0, "idx");
    check("idx record", sux.wrote && sux.idx == 16'd1 && sux.addr == APU_VGPU_SUN_IDX);
    sux_step(APU_VGPU_SUX_FAULT, 1'b0, 1'b0, "idx again");
    check("idx kept", sux.wrote && sux.idx == 16'd1 && writes == 5);

    if (errors != 0) $fatal(1, "APU vgpu sunw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_sunw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
