// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_cmd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v;
  logic [319:0] cmd;
  apu_vgpu_cpl_t cpl, off_cpl, snap;
  apu_vgpu_res_t slot0, slot1, off0, off1;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vgpu_cmd #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy), .cmd_i(cmd),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl),
    .slot0_o(slot0), .slot1_o(slot1)
  );
  g6lc_apu_vgpu_cmd_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy), .cmd_i(cmd),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .slot0_o(off0), .slot1_o(off1)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vgpu cmd timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_cpl !== '0 || off0 !== '0 || off1 !== '0)
      $fatal(1, "disabled vgpu cmd active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  function automatic logic [319:0] create2d(
    input logic [31:0] flags,
    input logic [63:0] fence_id,
    input logic [31:0] ctx_id,
    input logic [31:0] resource_id,
    input logic [31:0] format,
    input logic [31:0] width,
    input logic [31:0] height,
    input logic [31:0] padding
  );
    create2d = {height, width, format, resource_id, padding, ctx_id,
                fence_id, flags, VGPU_CMD_RESOURCE_CREATE_2D};
  endfunction

  task automatic issue(
    input logic [319:0] word,
    input logic [31:0] resp,
    input logic [31:0] flags,
    input logic [63:0] fence_id,
    input string name
  );
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    cmd = word;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    while (!cpl_v) @(negedge clk);
    snap = cpl;
    check($sformatf("%s type", name), cpl.resp_type == resp);
    check($sformatf("%s fence", name), cpl.flags == flags && cpl.fence_id == fence_id);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == snap);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [319:0] word;
    cmd = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep proto off", !ApuOff.ProtoEn && !ApuHarness.ProtoEn);
    cfg = ApuP1Transport;
    cfg.ProtoEn = 1'b1;
    check("proto does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.ProtoEn = 1'b1;
    check("proto does not legalize virgl", !apu_cfg_legal(cfg));

    word = create2d(32'h0, 64'h0, 32'h0, 32'd7, VGPU_FORMAT_R8G8B8A8_UNORM,
                     32'd4, 32'd2, 32'h0);
    issue(word, VGPU_RESP_OK_NODATA, 32'h0, 64'h0, "create");
    check("slot0 id", slot0.valid && slot0.resource_id == 32'd7 &&
          slot0.format == VGPU_FORMAT_R8G8B8A8_UNORM &&
          slot0.width == 32'd4 && slot0.height == 32'd2);
    check("slot1 empty", !slot1.valid);

    word = create2d(VGPU_FLAG_FENCE, 64'h1122_3344_5566_7788, 32'd3, 32'd8,
                     VGPU_FORMAT_R8G8B8A8_UNORM, 32'd1, 32'd1, 32'h0);
    issue(word, VGPU_RESP_OK_NODATA, VGPU_FLAG_FENCE, 64'h1122_3344_5566_7788, "fence");
    check("slot1 id", slot1.valid && slot1.resource_id == 32'd8 && slot1.width == 32'd1);
    check("fence keeps slot0", slot0.resource_id == 32'd7);

    word = {192'h0, 64'h99, 32'h0, 32'h0000_0207};
    issue(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "submit3d");
    check("submit keeps both", slot0.resource_id == 32'd7 && slot1.resource_id == 32'd8);

    word = create2d(VGPU_FLAG_FENCE, 64'h55, 32'd1, 32'd0,
                     VGPU_FORMAT_R8G8B8A8_UNORM, 32'd1, 32'd1, 32'h0);
    issue(word, VGPU_RESP_ERR_INVALID_RESOURCE_ID, VGPU_FLAG_FENCE, 64'h55, "id0");

    word = create2d(32'h0, 64'h0, 32'h0, 32'd9, 32'd1, 32'd4, 32'd2, 32'h0);
    issue(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "bgra");

    word = create2d(32'h0, 64'h0, 32'h0, 32'd7, VGPU_FORMAT_R8G8B8A8_UNORM,
                     32'd4, 32'd2, 32'h0);
    issue(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "duplicate");
    check("duplicate keeps slot0", slot0.resource_id == 32'd7 && slot0.height == 32'd2);

    word = create2d(32'h0, 64'h0, 32'h0, 32'd10, VGPU_FORMAT_R8G8B8A8_UNORM,
                     32'd1, 32'd1, 32'h0);
    issue(word, VGPU_RESP_ERR_OUT_OF_MEMORY, 32'h0, 64'h0, "full");

    word = create2d(32'h2, 64'h77, 32'h0, 32'd11, VGPU_FORMAT_R8G8B8A8_UNORM,
                     32'd1, 32'd1, 32'h0);
    issue(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "bad flag");

    word = create2d(32'h0, 64'h0, 32'h0, 32'd12, VGPU_FORMAT_R8G8B8A8_UNORM,
                     32'd0, 32'd1, 32'h0);
    issue(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "zero width");

    word = create2d(32'h0, 64'h0, 32'h0, 32'd13, VGPU_FORMAT_R8G8B8A8_UNORM,
                     32'd128, 32'd2, 32'h0);
    issue(word, VGPU_RESP_ERR_INVALID_PARAMETER, 32'h0, 64'h0, "too wide");
    check("table unchanged", slot0.resource_id == 32'd7 && slot1.resource_id == 32'd8);

    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("reset clears slots", !slot0.valid && !slot1.valid);
    word = create2d(VGPU_FLAG_FENCE, 64'h1122_3344_5566_7788, 32'd3, 32'd14,
                     VGPU_FORMAT_R8G8B8A8_UNORM, 32'd8, 32'd4, 32'h0);
    issue(word, VGPU_RESP_OK_NODATA, VGPU_FLAG_FENCE, 64'h1122_3344_5566_7788,
          "eight by four");
    check("grown slot", slot0.valid && slot0.resource_id == 32'd14 &&
          slot0.width == 32'd8 && slot0.height == 32'd4 && !slot1.valid);
    word = create2d(VGPU_FLAG_FENCE, 64'h1122_3344_5566_7788, 32'd3, 32'd15,
                     VGPU_FORMAT_R8G8B8A8_UNORM, 32'd16, 32'd8, 32'h0);
    issue(word, VGPU_RESP_OK_NODATA, VGPU_FLAG_FENCE, 64'h1122_3344_5566_7788,
          "sixteen by eight");
    check("wider slot", slot1.valid && slot1.resource_id == 32'd15 &&
          slot1.width == 32'd16 && slot1.height == 32'd8 &&
          slot0.resource_id == 32'd14);
    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    word = create2d(VGPU_FLAG_FENCE, 64'h1122_3344_5566_7788, 32'd3, 32'd16,
                     VGPU_FORMAT_R8G8B8A8_UNORM, 32'd32, 32'd16, 32'h0);
    issue(word, VGPU_RESP_OK_NODATA, VGPU_FLAG_FENCE, 64'h1122_3344_5566_7788,
          "thirty two by sixteen");
    check("ceiling slot", slot0.valid && slot0.resource_id == 32'd16 &&
          slot0.width == 32'd32 && slot0.height == 32'd16 && !slot1.valid);
    word = create2d(VGPU_FLAG_FENCE, 64'h1122_3344_5566_7788, 32'd3, 32'd17,
                     VGPU_FORMAT_R8G8B8A8_UNORM, 32'd64, 32'd32, 32'h0);
    issue(word, VGPU_RESP_OK_NODATA, VGPU_FLAG_FENCE, 64'h1122_3344_5566_7788,
          "sixty four by thirty two");
    check("scene width", slot1.valid && slot1.resource_id == 32'd17 &&
          slot1.width == 32'd64 && slot1.height == 32'd32 &&
          slot0.resource_id == 32'd16);
    @(negedge clk);
    rst_ni = 0;
    req_v = 0;
    cpl_r = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    word = create2d(VGPU_FLAG_FENCE, 64'h1122_3344_5566_7788, 32'd3, 32'd18,
                     VGPU_FORMAT_R8G8B8A8_UNORM, 32'd64, 32'd64, 32'h0);
    issue(word, VGPU_RESP_OK_NODATA, VGPU_FLAG_FENCE, 64'h1122_3344_5566_7788,
          "sixty four by sixty four");
    check("scene slot", slot0.valid && slot0.resource_id == 32'd18 &&
          slot0.width == 32'd64 && slot0.height == 32'd64 && !slot1.valid);

    if (errors != 0) $fatal(1, "APU vgpu cmd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_cmd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
