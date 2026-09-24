// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rdr;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_rbk_t rbk_in;
  apu_vgpu_smx_t smx_in;
  logic rdr_req = 0, rdr_rdy, rdr_cpl_v, rdr_cpl_r = 0;
  apu_vgpu_rdr_cpl_t rdr_cpl;
  apu_vgpu_rdr_t rdr;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen_last = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic rdk_req = 0, rdk_rdy, rdk_cpl_v, rdk_cpl_r = 0;
  apu_vgpu_rdk_cpl_t rdk_cpl, off_cpl;
  apu_vgpu_rdk_t rdk, off_rdk;
  logic off_rdy, off_v;
  logic fail_next = 0, zero_word = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Word0 = 32'hA500_0000;
  localparam logic [31:0] At30 = 32'h7878_7878;
  localparam logic [63:0] RbBase = 64'h0000_0000_8804_0000;
  localparam logic [63:0] RbLast = 64'h0000_0000_8804_3FE0;
  localparam logic [255:0] Beat0 = {
    32'h3344_5566, 32'h0B13_1C24, 32'h0404_0404, 32'h0303_0303,
    32'h0202_0202, 32'h8001_8001, 32'hD200_8000, 32'hA500_0000
  };

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_rdr #(.Enable(1'b1)) i_rdr (
    .clk_i(clk), .rst_ni, .rbk_i(rbk_in), .smx_i(smx_in),
    .req_valid_i(rdr_req), .req_ready_o(rdr_rdy),
    .cpl_valid_o(rdr_cpl_v), .cpl_ready_i(rdr_cpl_r), .cpl_o(rdr_cpl), .rdr_o(rdr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_rdk #(.Enable(1'b1)) i_rdk (
    .clk_i(clk), .rst_ni, .rdr_i(rdr), .rbk_i(rbk_in), .smx_i(smx_in),
    .req_valid_i(rdk_req), .req_ready_o(rdk_rdy),
    .cpl_valid_o(rdk_cpl_v), .cpl_ready_i(rdk_cpl_r), .cpl_o(rdk_cpl), .rdk_o(rdk)
  );
  g6lc_apu_vgpu_rdk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rdr_i(rdr), .rbk_i(rbk_in), .smx_i(smx_in),
    .req_valid_i(rdk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rdk_cpl_r), .cpl_o(off_cpl), .rdk_o(off_rdk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rdr timeout case=%0d n=%0d", cases, nread); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      int idx;
      idx = nread - run_base;
      if (rd_addr != RbBase + (64'(idx) << 5)) order_bad <= 1'b1;
      seen_last <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      if (idx == 0) rsp_data <= zero_word ? '0 : Beat0;
      else if (idx == 24) rsp_data <= {224'b0, At30};
      else rsp_data <= '0;
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      zero_word <= 1'b0;
      nread <= nread + 1;
      rsp_v <= 1'b1;
    end
  end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_rec;
    rbk_in = '0;
    rbk_in.valid = 1'b1;
    rbk_in.word0 = Word0;
    rbk_in.beats = 10'd512;
    rbk_in.last_addr = RbLast;
    smx_in = '0;
    smx_in.valid = 1'b1;
    smx_in.word = At30;
  endtask

  task automatic rdr_step(input apu_vgpu_rdr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rdr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    rdr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rdr_req = 1'b0;
    while (!rdr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rdr_cpl.status == st);
    if (st == APU_VGPU_RDR_OK) begin
      check("collected", rdr.valid && rdr.word0 == Word0 && rdr.at03 == At30 &&
            rdr.beats == 10'd512 && rdr.word0 != rdr.at03);
      check("read count", nread == n0 + 512 && !order_bad && seen_last == RbLast);
    end else if (name == "bad beat" || name == "bad word") begin
      check("one read", nread == n0 + 1 && !rdr.valid);
    end else begin
      check("no read", nread == n0);
    end
    @(negedge clk);
    check($sformatf("%s held", name), rdr_cpl_v);
    rdr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rdr_cpl_r = 1'b0;
    while (rdr_cpl_v) @(negedge clk);
  endtask

  task automatic rdk_step(input apu_vgpu_rdk_status_e st, input string name);
    @(negedge clk);
    while (!rdk_rdy) @(negedge clk);
    cases++;
    rdk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rdk_req = 1'b0;
    while (!rdk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rdk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rdk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), rdk_cpl_v);
    rdk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rdk_cpl_r = 1'b0;
    while (rdk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rdr_req = 1'b0;
    rdk_req = 1'b0;
    rdr_cpl_r = 1'b0;
    rdk_cpl_r = 1'b0;
    rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    rbk_in = '0;
    smx_in = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && rdr == '0 &&
          rdk == '0);
    check("profiles keep the collect off",
          !ApuOff.RdrEn && !ApuOff.RdkEn &&
          !ApuP1Transport.RdrEn && !ApuP1Transport.RdkEn &&
          !ApuHarness.RdrEn && !ApuHarness.RdkEn &&
          !ApuSchedBoth.RdrEn && !ApuSchedBoth.RdkEn &&
          !ApuBadVirglGrant.RdrEn && !ApuBadVirglGrant.RdkEn);
    cfg = ApuP1Transport;
    cfg.RdrEn = 1'b1;
    cfg.RdkEn = 1'b1;
    check("collect does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.RdrEn = 1'b1;
    cfg.RdkEn = 1'b1;
    check("collect does not legalize virgl", !apu_cfg_legal(cfg));
    check("last beat", RbLast == RbBase + (64'd511 << 5));

    rdr_step(APU_VGPU_RDR_EMPTY, "rdr empty");
    good_rec();
    fail_next = 1'b1;
    rdr_step(APU_VGPU_RDR_FAULT, "bad beat");
    zero_word = 1'b1;
    rdr_step(APU_VGPU_RDR_FAULT, "bad word");
    rdr_step(APU_VGPU_RDR_OK, "ceiling read");
    rdk_step(APU_VGPU_RDK_OK, "keep pair");
    check("pair kept", rdk.valid && rdk.word0 == Word0 && rdk.at03 == At30);
    rdk_step(APU_VGPU_RDK_FAULT, "pair again");
    check("pair stays", rdk.word0 == Word0 && rdk.at03 == At30 &&
          rbk_in.word0 == Word0 && smx_in.word == At30);

    pulse_reset();
    check("reset clears", rdr == '0 && rdk == '0);
    rdk_step(APU_VGPU_RDK_EMPTY, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu rdr errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rdr cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
