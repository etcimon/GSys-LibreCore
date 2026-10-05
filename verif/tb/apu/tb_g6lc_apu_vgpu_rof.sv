// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rof;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_grd_t grd;
  apu_vgpu_grx_t grx;
  logic [6:0] px = 0, py = 0;
  logic rof_req = 0, rof_rdy, rof_cpl_v, rof_cpl_r = 0;
  apu_vgpu_rof_cpl_t rof_cpl;
  apu_vgpu_rof_t rof;
  logic ror_req = 0, ror_rdy, ror_cpl_v, ror_cpl_r = 0;
  apu_vgpu_ror_cpl_t ror_cpl;
  apu_vgpu_ror_t ror;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic [7:0] b0 = 0;
  logic rox_req = 0, rox_rdy, rox_cpl_v, rox_cpl_r = 0;
  apu_vgpu_rox_cpl_t rox_cpl, off_cpl;
  apu_vgpu_rox_t rox, off_rox;
  logic off_rdy, off_v;
  logic fail_rd = 0, clear_lane = 0, swap_lanes = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [31:0] Origin = 32'hA500_0000;
  localparam logic [31:0] Neighbor = 32'hD200_8000;
  localparam logic [255:0] Beat0 = {192'b0, Neighbor, Origin};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_rof #(.Enable(1'b1)) i_rof (
    .clk_i(clk), .rst_ni, .grd_i(grd), .grx_i(grx), .x_i(px), .y_i(py),
    .req_valid_i(rof_req), .req_ready_o(rof_rdy),
    .cpl_valid_o(rof_cpl_v), .cpl_ready_i(rof_cpl_r), .cpl_o(rof_cpl), .rof_o(rof)
  );
  g6lc_apu_vgpu_ror #(.Enable(1'b1)) i_ror (
    .clk_i(clk), .rst_ni, .grd_i(grd), .grx_i(grx), .x_i(px), .y_i(py),
    .req_valid_i(ror_req), .req_ready_o(ror_rdy),
    .cpl_valid_o(ror_cpl_v), .cpl_ready_i(ror_cpl_r), .cpl_o(ror_cpl), .ror_o(ror),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rox #(.Enable(1'b1)) i_rox (
    .clk_i(clk), .rst_ni, .ror_i(ror), .grd_i(grd), .b0_i(b0),
    .req_valid_i(rox_req), .req_ready_o(rox_rdy),
    .cpl_valid_o(rox_cpl_v), .cpl_ready_i(rox_cpl_r), .cpl_o(rox_cpl), .rox_o(rox)
  );
  g6lc_apu_vgpu_rox_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .ror_i(ror), .grd_i(grd), .b0_i(b0),
    .req_valid_i(rox_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rox_cpl_r), .cpl_o(off_cpl), .rox_o(off_rox)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rof timeout case=%0d", cases); end

  function automatic logic [15:0] pix_off(input logic [6:0] x, input logic [6:0] y);
    pix_off = {2'b0, y[5:0], 8'h00} + {8'h00, x[5:0], 2'b00};
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Beat0;
      if (clear_lane) beat[31:0] = APU_VGPU_CLEAR_WORD;
      if (swap_lanes) beat = {192'b0, beat[31:0], beat[63:32]};
      if (rd_addr != APU_VGPU_RPW_DST || rd_len != 32'(APU_VGPU_BEAT_BYTES))
        order_bad <= 1'b1;
      seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      clear_lane <= 1'b0;
      swap_lanes <= 1'b0;
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
    grd = '0;
    grd.valid = 1'b1;
    grd.width = APU_VGPU_GBD_W;
    grd.height = APU_VGPU_GBD_H;
    grd.stride = APU_VGPU_GBD_STRIDE;
    grd.bytes = APU_VGPU_GBD_BYTES;
    grd.format = APU_VIRGL_FMT_B8G8R8X8;
    grd.base = APU_VGPU_RPW_DST;
    grd.origin = Origin;
    grd.neighbor = Neighbor;
    grd.cmd = VGPU_CMD_TRANSFER_FROM_HOST_3D;
    grx = '0;
    grx.valid = 1'b1;
    grx.b0 = Neighbor[7:0];
    grx.word = Neighbor;
    grx.x = 7'd1;
    grx.y = 7'd0;
    grx.addr = APU_VGPU_RPW_DST;
    px = 7'd0;
    py = 7'd0;
    b0 = Origin[7:0];
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rox == '0 &&
          off_cpl == '0);
  endtask

  task automatic rof_step(input apu_vgpu_rof_status_e st, input string name);
    @(negedge clk);
    while (!rof_rdy) @(negedge clk);
    cases++;
    rof_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rof_req = 1'b0;
    while (!rof_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rof_cpl.status == st);
    quiet();
    if (st == APU_VGPU_ROF_OK) begin
      check("offset", rof.valid && rof.x == px && rof.y == py &&
            rof.offset == pix_off(px, py) &&
            rof.addr != APU_VGPU_CSW_DST);
    end
    @(negedge clk);
    check($sformatf("%s held", name), rof_cpl_v);
    rof_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rof_cpl_r = 1'b0;
    while (rof_cpl_v) @(negedge clk);
  endtask

  task automatic ror_step(input apu_vgpu_ror_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!ror_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    ror_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ror_req = 1'b0;
    while (!ror_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ror_cpl.status == st);
    quiet();
    if (st == APU_VGPU_ROR_OK) begin
      check("origin", ror.valid && ror.x == 7'd0 && ror.y == 7'd0 &&
            ror.offset == 16'd0 && ror.word == Origin &&
            ror.word != Neighbor && ror.word != APU_VGPU_CLEAR_WORD &&
            ror.addr == APU_VGPU_RPW_DST);
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_RPW_DST);
    end else if (name == "bad beat" || name == "clear lane" ||
                 name == "swapped lanes") begin
      check("one read failed", nread == n0 + 1 && !ror.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), ror_cpl_v);
    ror_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ror_cpl_r = 1'b0;
    while (ror_cpl_v) @(negedge clk);
  endtask

  task automatic rox_step(input apu_vgpu_rox_status_e st, input string name);
    @(negedge clk);
    while (!rox_rdy) @(negedge clk);
    cases++;
    rox_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rox_req = 1'b0;
    while (!rox_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rox_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rox_cpl_v);
    rox_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rox_cpl_r = 1'b0;
    while (rox_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rof_req = 1'b0;
    ror_req = 1'b0;
    rox_req = 1'b0;
    rof_cpl_r = 1'b0;
    ror_cpl_r = 1'b0;
    rox_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    grd = '0;
    grx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rof == '0 && ror == '0 && rox == '0);
    check("profiles keep the offset off",
          !ApuOff.RofEn && !ApuOff.RorEn && !ApuOff.RoxEn &&
          !ApuP1Transport.RofEn && !ApuP1Transport.RorEn &&
          !ApuP1Transport.RoxEn &&
          !ApuHarness.RofEn && !ApuHarness.RorEn && !ApuHarness.RoxEn &&
          !ApuSchedBoth.RofEn && !ApuSchedBoth.RorEn && !ApuSchedBoth.RoxEn &&
          !ApuBadVirglGrant.RofEn && !ApuBadVirglGrant.RorEn &&
          !ApuBadVirglGrant.RoxEn);
    cfg = ApuP1Transport;
    cfg.RofEn = 1'b1;
    cfg.RorEn = 1'b1;
    cfg.RoxEn = 1'b1;
    check("offset does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RofEn = 1'b1;
    cfg.RorEn = 1'b1;
    cfg.RoxEn = 1'b1;
    check("offset does not legalize virgl", !apu_cfg_legal(cfg));
    check("known offsets",
          pix_off(7'd0, 7'd0) == 16'd0 &&
          pix_off(7'd1, 7'd0) == 16'd4 &&
          pix_off(7'd63, 7'd63) == 16'd16380 &&
          APU_VGPU_RPW_TAIL == APU_VGPU_RPW_DST + (64'(APU_VGPU_GPW_LAST) << 5) &&
          32'(16'd16380) + 32'd4 == APU_VGPU_GBD_BYTES &&
          Origin != Neighbor && Origin != APU_VGPU_CLEAR_WORD &&
          Origin[7:0] != APU_VGPU_CLEAR_R);

    rof_step(APU_VGPU_ROF_EMPTY, "offset empty");
    ror_step(APU_VGPU_ROR_EMPTY, "origin empty");
    rox_step(APU_VGPU_ROX_EMPTY, "order empty");
    good_in();
    px = 7'd64;
    py = 7'd0;
    rof_step(APU_VGPU_ROF_FAULT, "x past");
    px = 7'd0;
    py = 7'd64;
    rof_step(APU_VGPU_ROF_FAULT, "y past");
    px = 7'd1;
    py = 7'd0;
    rof_step(APU_VGPU_ROF_OK, "pixel 1 0");
    check("byte 4", rof.offset == 16'd4 && rof.addr == APU_VGPU_RPW_DST);
    rof_step(APU_VGPU_ROF_FAULT, "offset again");
    px = 7'd1;
    py = 7'd0;
    ror_step(APU_VGPU_ROR_FAULT, "blend point");
    check("blend rejected", !ror.valid);
    px = 7'd0;
    py = 7'd1;
    ror_step(APU_VGPU_ROR_FAULT, "next row");
    px = 7'd0;
    py = 7'd0;
    fail_rd = 1'b1;
    ror_step(APU_VGPU_ROR_FAULT, "bad beat");
    clear_lane = 1'b1;
    ror_step(APU_VGPU_ROR_FAULT, "clear lane");
    swap_lanes = 1'b1;
    ror_step(APU_VGPU_ROR_FAULT, "swapped lanes");
    ror_step(APU_VGPU_ROR_OK, "clamp texel");
    ror_step(APU_VGPU_ROR_FAULT, "origin again");
    check("origin stays", ror.word == Origin && ror.offset == 16'd0 &&
          ror.x == 7'd0);
    b0 = APU_VGPU_CLEAR_R;
    rox_step(APU_VGPU_ROX_FAULT, "clear red first");
    check("clear red rejected", !rox.valid);
    b0 = APU_VGPU_CLEAR_B;
    rox_step(APU_VGPU_ROX_FAULT, "blue first");
    check("blue rejected", !rox.valid);
    b0 = APU_VGPU_CLEAR_A;
    rox_step(APU_VGPU_ROX_FAULT, "high byte first");
    check("high byte rejected", !rox.valid);
    b0 = Origin[7:0];
    rox_step(APU_VGPU_ROX_OK, "sample red first");
    check("sample red", rox.valid && rox.b0 == 8'h00 && rox.x == 7'd0 &&
          rox.word == Origin && rox.word != Neighbor);
    rox_step(APU_VGPU_ROX_FAULT, "order again");
    check("order stays", rox.b0 == 8'h00 && rox.word == Origin);

    pulse_reset();
    check("reset clears", rof == '0 && ror == '0 && rox == '0);
    grd = '0;
    grx = '0;
    rof_step(APU_VGPU_ROF_EMPTY, "after reset");
    good_in();
    px = 7'd63;
    py = 7'd63;
    rof_step(APU_VGPU_ROF_OK, "pixel 63 63");
    check("last byte", rof.offset == 16'd16380 && rof.addr == APU_VGPU_RPW_TAIL);

    if (errors != 0) $fatal(1, "APU vgpu rof errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rof cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
