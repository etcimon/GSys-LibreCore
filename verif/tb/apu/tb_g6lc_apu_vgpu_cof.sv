// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_cof;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_crd_t crd;
  apu_vgpu_crx_t crx;
  logic [6:0] px = 0, py = 0;
  logic cof_req = 0, cof_rdy, cof_cpl_v, cof_cpl_r = 0;
  apu_vgpu_cof_cpl_t cof_cpl;
  apu_vgpu_cof_t cof;
  logic cor_req = 0, cor_rdy, cor_cpl_v, cor_cpl_r = 0;
  apu_vgpu_cor_cpl_t cor_cpl;
  apu_vgpu_cor_t cor;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic [7:0] b0 = 0;
  logic cox_req = 0, cox_rdy, cox_cpl_v, cox_cpl_r = 0;
  apu_vgpu_cox_cpl_t cox_cpl, off_cpl;
  apu_vgpu_cox_t cox, off_cox;
  logic off_rdy, off_v;
  logic fail_rd = 0, clear_lane = 0, swap_lanes = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [31:0] Origin = 32'hA500_0000;
  localparam logic [31:0] Neighbor = 32'hD200_8000;
  localparam logic [255:0] Beat0 = {192'b0, Neighbor, Origin};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_cof #(.Enable(1'b1)) i_cof (
    .clk_i(clk), .rst_ni, .crd_i(crd), .crx_i(crx), .x_i(px), .y_i(py),
    .req_valid_i(cof_req), .req_ready_o(cof_rdy),
    .cpl_valid_o(cof_cpl_v), .cpl_ready_i(cof_cpl_r), .cpl_o(cof_cpl), .cof_o(cof)
  );
  g6lc_apu_vgpu_cor #(.Enable(1'b1)) i_cor (
    .clk_i(clk), .rst_ni, .crd_i(crd), .crx_i(crx), .x_i(px), .y_i(py),
    .req_valid_i(cor_req), .req_ready_o(cor_rdy),
    .cpl_valid_o(cor_cpl_v), .cpl_ready_i(cor_cpl_r), .cpl_o(cor_cpl), .cor_o(cor),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_cox #(.Enable(1'b1)) i_cox (
    .clk_i(clk), .rst_ni, .cor_i(cor), .crd_i(crd), .b0_i(b0),
    .req_valid_i(cox_req), .req_ready_o(cox_rdy),
    .cpl_valid_o(cox_cpl_v), .cpl_ready_i(cox_cpl_r), .cpl_o(cox_cpl), .cox_o(cox)
  );
  g6lc_apu_vgpu_cox_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cor_i(cor), .crd_i(crd), .b0_i(b0),
    .req_valid_i(cox_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cox_cpl_r), .cpl_o(off_cpl), .cox_o(off_cox)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu cof timeout case=%0d", cases); end

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
      if (rd_addr != APU_VGPU_CSW_DST || rd_len != 32'(APU_VGPU_BEAT_BYTES))
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
    crd = '0;
    crd.valid = 1'b1;
    crd.width = APU_VGPU_GBD_W;
    crd.height = APU_VGPU_GBD_H;
    crd.stride = APU_VGPU_GBD_STRIDE;
    crd.bytes = APU_VGPU_GBD_BYTES;
    crd.format = APU_VIRGL_FMT_B8G8R8X8;
    crd.base = APU_VGPU_CSW_DST;
    crd.origin = Origin;
    crd.neighbor = Neighbor;
    crx = '0;
    crx.valid = 1'b1;
    crx.b0 = Neighbor[7:0];
    crx.word = Neighbor;
    crx.x = 7'd1;
    crx.y = 7'd0;
    crx.addr = APU_VGPU_CSW_DST;
    px = 7'd0;
    py = 7'd0;
    b0 = Origin[7:0];
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_cox == '0 &&
          off_cpl == '0);
  endtask

  task automatic cof_step(input apu_vgpu_cof_status_e st, input string name);
    @(negedge clk);
    while (!cof_rdy) @(negedge clk);
    cases++;
    cof_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cof_req = 1'b0;
    while (!cof_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cof_cpl.status == st);
    quiet();
    if (st == APU_VGPU_COF_OK) begin
      check("offset", cof.valid && cof.x == px && cof.y == py &&
            cof.offset == pix_off(px, py) &&
            cof.addr != APU_VGPU_GBW_ADDR);
    end
    @(negedge clk);
    check($sformatf("%s held", name), cof_cpl_v);
    cof_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cof_cpl_r = 1'b0;
    while (cof_cpl_v) @(negedge clk);
  endtask

  task automatic cor_step(input apu_vgpu_cor_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!cor_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    cor_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cor_req = 1'b0;
    while (!cor_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cor_cpl.status == st);
    quiet();
    if (st == APU_VGPU_COR_OK) begin
      check("origin", cor.valid && cor.x == 7'd0 && cor.y == 7'd0 &&
            cor.offset == 16'd0 && cor.word == Origin &&
            cor.word != Neighbor && cor.word != APU_VGPU_CLEAR_WORD &&
            cor.addr == APU_VGPU_CSW_DST);
      check("one read", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_CSW_DST);
    end else if (name == "bad beat" || name == "clear lane" ||
                 name == "swapped lanes") begin
      check("one read failed", nread == n0 + 1 && !cor.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), cor_cpl_v);
    cor_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cor_cpl_r = 1'b0;
    while (cor_cpl_v) @(negedge clk);
  endtask

  task automatic cox_step(input apu_vgpu_cox_status_e st, input string name);
    @(negedge clk);
    while (!cox_rdy) @(negedge clk);
    cases++;
    cox_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cox_req = 1'b0;
    while (!cox_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cox_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), cox_cpl_v);
    cox_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cox_cpl_r = 1'b0;
    while (cox_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    cof_req = 1'b0;
    cor_req = 1'b0;
    cox_req = 1'b0;
    cof_cpl_r = 1'b0;
    cor_cpl_r = 1'b0;
    cox_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    crd = '0;
    crx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          cof == '0 && cor == '0 && cox == '0);
    check("profiles keep the offset off",
          !ApuOff.CofEn && !ApuOff.CorEn && !ApuOff.CoxEn &&
          !ApuP1Transport.CofEn && !ApuP1Transport.CorEn &&
          !ApuP1Transport.CoxEn &&
          !ApuHarness.CofEn && !ApuHarness.CorEn && !ApuHarness.CoxEn &&
          !ApuSchedBoth.CofEn && !ApuSchedBoth.CorEn && !ApuSchedBoth.CoxEn &&
          !ApuBadVirglGrant.CofEn && !ApuBadVirglGrant.CorEn &&
          !ApuBadVirglGrant.CoxEn);
    cfg = ApuP1Transport;
    cfg.CofEn = 1'b1;
    cfg.CorEn = 1'b1;
    cfg.CoxEn = 1'b1;
    check("offset does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.CofEn = 1'b1;
    cfg.CorEn = 1'b1;
    cfg.CoxEn = 1'b1;
    check("offset does not legalize virgl", !apu_cfg_legal(cfg));
    check("known offsets",
          pix_off(7'd0, 7'd0) == 16'd0 &&
          pix_off(7'd1, 7'd0) == 16'd4 &&
          pix_off(7'd63, 7'd63) == 16'd16380 &&
          APU_VGPU_CSW_TAIL == APU_VGPU_CSW_DST + (64'(APU_VGPU_GPW_LAST) << 5) &&
          32'(16'd16380) + 32'd4 == APU_VGPU_GBD_BYTES &&
          Origin != Neighbor && Origin != APU_VGPU_CLEAR_WORD &&
          Origin[7:0] != APU_VGPU_CLEAR_R);

    cof_step(APU_VGPU_COF_EMPTY, "offset empty");
    cor_step(APU_VGPU_COR_EMPTY, "origin empty");
    cox_step(APU_VGPU_COX_EMPTY, "order empty");
    good_in();
    px = 7'd64;
    py = 7'd0;
    cof_step(APU_VGPU_COF_FAULT, "x past");
    px = 7'd0;
    py = 7'd64;
    cof_step(APU_VGPU_COF_FAULT, "y past");
    px = 7'd1;
    py = 7'd0;
    cof_step(APU_VGPU_COF_OK, "pixel 1 0");
    check("byte 4", cof.offset == 16'd4 && cof.addr == APU_VGPU_CSW_DST);
    cof_step(APU_VGPU_COF_FAULT, "offset again");
    px = 7'd1;
    py = 7'd0;
    cor_step(APU_VGPU_COR_FAULT, "blend point");
    check("blend rejected", !cor.valid);
    px = 7'd0;
    py = 7'd1;
    cor_step(APU_VGPU_COR_FAULT, "next row");
    px = 7'd0;
    py = 7'd0;
    fail_rd = 1'b1;
    cor_step(APU_VGPU_COR_FAULT, "bad beat");
    clear_lane = 1'b1;
    cor_step(APU_VGPU_COR_FAULT, "clear lane");
    swap_lanes = 1'b1;
    cor_step(APU_VGPU_COR_FAULT, "swapped lanes");
    cor_step(APU_VGPU_COR_OK, "clamp texel");
    cor_step(APU_VGPU_COR_FAULT, "origin again");
    check("origin stays", cor.word == Origin && cor.offset == 16'd0 &&
          cor.x == 7'd0);
    b0 = APU_VGPU_CLEAR_R;
    cox_step(APU_VGPU_COX_FAULT, "clear red first");
    check("clear red rejected", !cox.valid);
    b0 = APU_VGPU_CLEAR_B;
    cox_step(APU_VGPU_COX_FAULT, "blue first");
    check("blue rejected", !cox.valid);
    b0 = APU_VGPU_CLEAR_A;
    cox_step(APU_VGPU_COX_FAULT, "high byte first");
    check("high byte rejected", !cox.valid);
    b0 = Origin[7:0];
    cox_step(APU_VGPU_COX_OK, "sample red first");
    check("sample red", cox.valid && cox.b0 == 8'h00 && cox.x == 7'd0 &&
          cox.word == Origin && cox.word != Neighbor);
    cox_step(APU_VGPU_COX_FAULT, "order again");
    check("order stays", cox.b0 == 8'h00 && cox.word == Origin);

    pulse_reset();
    check("reset clears", cof == '0 && cor == '0 && cox == '0);
    crd = '0;
    crx = '0;
    cof_step(APU_VGPU_COF_EMPTY, "after reset");
    good_in();
    px = 7'd63;
    py = 7'd63;
    cof_step(APU_VGPU_COF_OK, "pixel 63 63");
    check("last byte", cof.offset == 16'd16380 && cof.addr == APU_VGPU_CSW_TAIL);

    if (errors != 0) $fatal(1, "APU vgpu cof errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_cof cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
