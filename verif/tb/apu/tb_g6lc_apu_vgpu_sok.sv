// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_sok;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_swx_t swx;
  logic sok_req = 0, sok_rdy, sok_cpl_v, sok_cpl_r = 0;
  apu_vgpu_sok_cpl_t sok_cpl;
  apu_vgpu_sok_t sok;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic sol_req = 0, sol_rdy, sol_cpl_v, sol_cpl_r = 0;
  apu_vgpu_sol_cpl_t sol_cpl;
  apu_vgpu_sol_t sol;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic sox_req = 0, sox_rdy, sox_cpl_v, sox_cpl_r = 0;
  apu_vgpu_sox_cpl_t sox_cpl, off_cpl;
  apu_vgpu_sox_t sox, off_sox;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, xfer_fence = 0, no_flag = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0, nread = 0;

  localparam logic [255:0] RespBeat = {64'h0, 32'h0, APU_VGPU_CTX_ID,
                                       APU_VGPU_SCENE_FENCE, VGPU_FLAG_FENCE,
                                       VGPU_RESP_OK_NODATA};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_sok #(.Enable(1'b1)) i_sok (
    .clk_i(clk), .rst_ni, .swx_i(swx),
    .req_valid_i(sok_req), .req_ready_o(sok_rdy),
    .cpl_valid_o(sok_cpl_v), .cpl_ready_i(sok_cpl_r), .cpl_o(sok_cpl), .sok_o(sok),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_sol #(.Enable(1'b1)) i_sol (
    .clk_i(clk), .rst_ni, .sok_i(sok), .swx_i(swx),
    .req_valid_i(sol_req), .req_ready_o(sol_rdy),
    .cpl_valid_o(sol_cpl_v), .cpl_ready_i(sol_cpl_r), .cpl_o(sol_cpl), .sol_o(sol),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_sox #(.Enable(1'b1)) i_sox (
    .clk_i(clk), .rst_ni, .sol_i(sol), .sok_i(sok), .swx_i(swx),
    .req_valid_i(sox_req), .req_ready_o(sox_rdy),
    .cpl_valid_o(sox_cpl_v), .cpl_ready_i(sox_cpl_r), .cpl_o(sox_cpl), .sox_o(sox)
  );
  g6lc_apu_vgpu_sox_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .sol_i(sol), .sok_i(sok), .swx_i(swx),
    .req_valid_i(sox_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(sox_cpl_r), .cpl_o(off_cpl), .sox_o(off_sox)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu sok timeout case=%0d", cases); end

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
      if (wr_addr != APU_VGPU_RSP_ADDR || wr_len != VGPU_RESP_HDR_BYTES)
        order_bad <= 1'b1;
      if (wr_data[191:0] != RespBeat[191:0]) data_bad <= 1'b1;
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
      beat = stored_v ? stored : RespBeat;
      if (xfer_fence) beat[127:64] = APU_VGPU_RFW_FENCE;
      if (no_flag) beat[63:32] = 32'h0;
      if (rd_addr != APU_VGPU_RSP_ADDR || rd_len != VGPU_RESP_HDR_BYTES)
        rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      xfer_fence <= 1'b0;
      no_flag <= 1'b0;
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
    swx = '0;
    swx.valid = 1'b1;
    swx.rsp_addr = APU_VGPU_RSP_ADDR;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_sox == '0 &&
          off_cpl == '0);
  endtask

  task automatic sok_step(input apu_vgpu_sok_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!sok_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    sok_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sok_req = 1'b0;
    while (!sok_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sok_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SOK_OK) begin
      check("response", sok.valid && sok.resp == VGPU_RESP_OK_NODATA &&
            sok.fence == APU_VGPU_SCENE_FENCE &&
            sok.fence != APU_VGPU_RFW_FENCE &&
            sok.addr == APU_VGPU_RSP_ADDR && sok.addr != APU_VGPU_RFW_ADDR);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_RSP_ADDR && wr_seen != APU_VGPU_SWD_ADDR);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !sok.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), sok_cpl_v);
    sok_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sok_cpl_r = 1'b0;
    while (sok_cpl_v) @(negedge clk);
  endtask

  task automatic sol_step(input apu_vgpu_sol_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!sol_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    sol_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sol_req = 1'b0;
    while (!sol_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sol_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SOL_OK) begin
      check("echo", sol.valid && sol.fence == APU_VGPU_SCENE_FENCE &&
            sol.fence != APU_VGPU_RFW_FENCE &&
            sol.flg == VGPU_FLAG_FENCE &&
            sol.resp == VGPU_RESP_OK_NODATA &&
            sol.addr == APU_VGPU_RSP_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_RSP_ADDR);
    end else if (name == "bad read" || name == "xfer fence" ||
                 name == "no flag") begin
      check("one read failed", nread == n0 + 1 && !sol.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), sol_cpl_v);
    sol_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sol_cpl_r = 1'b0;
    while (sol_cpl_v) @(negedge clk);
  endtask

  task automatic sox_step(input apu_vgpu_sox_status_e st, input string name);
    @(negedge clk);
    while (!sox_rdy) @(negedge clk);
    cases++;
    sox_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sox_req = 1'b0;
    while (!sox_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sox_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), sox_cpl_v);
    sox_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sox_cpl_r = 1'b0;
    while (sox_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    sok_req = 1'b0;
    sol_req = 1'b0;
    sox_req = 1'b0;
    sok_cpl_r = 1'b0;
    sol_cpl_r = 1'b0;
    sox_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    stored_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    swx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          sok == '0 && sol == '0 && sox == '0);
    check("profiles keep the nodata off",
          !ApuOff.SokEn && !ApuOff.SolEn && !ApuOff.SoxEn &&
          !ApuP1Transport.SokEn && !ApuP1Transport.SolEn &&
          !ApuP1Transport.SoxEn &&
          !ApuHarness.SokEn && !ApuHarness.SolEn && !ApuHarness.SoxEn &&
          !ApuSchedBoth.SokEn && !ApuSchedBoth.SolEn && !ApuSchedBoth.SoxEn &&
          !ApuBadVirglGrant.SokEn && !ApuBadVirglGrant.SolEn &&
          !ApuBadVirglGrant.SoxEn);
    cfg = ApuP1Transport;
    cfg.SokEn = 1'b1;
    cfg.SolEn = 1'b1;
    cfg.SoxEn = 1'b1;
    check("nodata does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.SokEn = 1'b1;
    cfg.SolEn = 1'b1;
    cfg.SoxEn = 1'b1;
    check("nodata does not legalize virgl", !apu_cfg_legal(cfg));
    check("nodata places",
          APU_VGPU_RSP_ADDR != APU_VGPU_RFW_ADDR &&
          APU_VGPU_RSP_ADDR != APU_VGPU_SWD_ADDR &&
          APU_VGPU_SCENE_FENCE == 64'h1122334455667788 &&
          APU_VGPU_SCENE_FENCE != APU_VGPU_RFW_FENCE &&
          VGPU_RESP_HDR_BYTES == 32'd24);

    sok_step(APU_VGPU_SOK_EMPTY, "write empty");
    sol_step(APU_VGPU_SOL_EMPTY, "read empty");
    sox_step(APU_VGPU_SOX_EMPTY, "check empty");
    good_in();
    swx.rsp_addr = APU_VGPU_RFW_ADDR;
    sok_step(APU_VGPU_SOK_FAULT, "xfer dest");
    good_in();
    fail_wr = 1'b1;
    sok_step(APU_VGPU_SOK_FAULT, "bad write");
    sok_step(APU_VGPU_SOK_OK, "ok nodata");
    sok_step(APU_VGPU_SOK_FAULT, "write again");
    fail_rd = 1'b1;
    sol_step(APU_VGPU_SOL_FAULT, "bad read");
    xfer_fence = 1'b1;
    sol_step(APU_VGPU_SOL_FAULT, "xfer fence");
    no_flag = 1'b1;
    sol_step(APU_VGPU_SOL_FAULT, "no flag");
    sol_step(APU_VGPU_SOL_OK, "echo fence");
    sol_step(APU_VGPU_SOL_FAULT, "read again");
    swx.rsp_addr = APU_VGPU_RFW_ADDR;
    sox_step(APU_VGPU_SOX_FAULT, "check xfer dest");
    check("check rejected", !sox.valid);
    good_in();
    sox_step(APU_VGPU_SOX_OK, "check fence");
    check("fence checked", sox.valid && sox.fence == APU_VGPU_SCENE_FENCE &&
          sox.resp == VGPU_RESP_OK_NODATA);
    sox_step(APU_VGPU_SOX_FAULT, "check again");
    check("check stays", sox.fence == sok.fence);

    pulse_reset();
    check("reset clears", sok == '0 && sol == '0 && sox == '0);
    swx = '0;
    sok_step(APU_VGPU_SOK_EMPTY, "after reset");
    good_in();
    sok_step(APU_VGPU_SOK_OK, "nodata after reset");

    if (errors != 0) $fatal(1, "APU vgpu sok errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_sok cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
