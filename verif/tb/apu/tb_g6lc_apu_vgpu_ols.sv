// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_ols;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_nxc_t nxc;
  apu_vgpu_cap_t cap;
  apu_vgpu_nfo_t nfo;
  apu_vgpu_sfc_t sfc;
  apu_vgpu_fet_t fet;
  apu_vgpu_qdr_t qdr;
  logic ols_req = 0, ols_rdy, ols_cpl_v, ols_cpl_r = 0;
  apu_vgpu_ols_cpl_t ols_cpl;
  apu_vgpu_ols_t ols;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic [63:0] rd_addr, rsp_addr = 0, seen = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic olk_req = 0, olk_rdy, olk_cpl_v, olk_cpl_r = 0;
  apu_vgpu_olk_cpl_t olk_cpl, off_cpl;
  apu_vgpu_olk_t olk, off_olk;
  logic off_rdy, off_v;
  logic fail_next = 0, bad_count = 0, bad_id = 0, order_bad = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0, run_base = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  g6lc_apu_vgpu_ols #(.Enable(1'b1)) i_ols (
    .clk_i(clk), .rst_ni, .nxc_i(nxc), .cap_i(cap), .nfo_i(nfo), .sfc_i(sfc),
    .fet_i(fet), .qdr_i(qdr),
    .req_valid_i(ols_req), .req_ready_o(ols_rdy),
    .cpl_valid_o(ols_cpl_v), .cpl_ready_i(ols_cpl_r), .cpl_o(ols_cpl), .ols_o(ols),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_olk #(.Enable(1'b1)) i_olk (
    .clk_i(clk), .rst_ni, .ols_i(ols), .nxc_i(nxc), .cap_i(cap), .nfo_i(nfo),
    .fet_i(fet), .req_valid_i(olk_req), .req_ready_o(olk_rdy),
    .cpl_valid_o(olk_cpl_v), .cpl_ready_i(olk_cpl_r), .cpl_o(olk_cpl), .olk_o(olk)
  );
  g6lc_apu_vgpu_olk_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .ols_i(ols), .nxc_i(nxc), .cap_i(cap), .nfo_i(nfo),
    .fet_i(fet), .req_valid_i(olk_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(olk_cpl_r), .cpl_o(off_cpl), .olk_o(off_olk)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu ols timeout case=%0d n=%0d", cases, nread); end

  function automatic logic [255:0] beat_data();
    beat_data = '0;
    beat_data[31:0] = bad_count ? 32'(APU_VIRGL_CREATE_OBJECT) : 32'h0;
    beat_data[63:32] = bad_id ? APU_VGPU_CAPSET_VIRGL : 32'h0;
    beat_data[95:64] = 32'h1;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      nread <= 0;
      order_bad <= 1'b0;
    end else if (rsp_v && rsp_rdy) rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      if (rd_addr != APU_VGPU_OLS_ADDR) order_bad <= 1'b1;
      seen <= rd_addr;
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= beat_data();
      rsp_ok <= !fail_next;
      fail_next <= 1'b0;
      bad_count <= 1'b0;
      bad_id <= 1'b0;
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

  task automatic good_in;
    nxc = '0;
    nxc.valid = 1'b1;
    nxc.head = 16'd0;
    nxc.avail_idx = 16'd1;
    nxc.buf_len = APU_VGPU_SCENE_BYTES;
    nxc.buf_addr = APU_VGPU_EXEC_ADDR;
    nxc.rsp_addr = APU_VGPU_RSP_ADDR;
    cap = '0;
    cap.refused = 1'b1;
    cap.resp = VGPU_RESP_ERR_INVALID_PARAMETER;
    nfo = '0;
    nfo.refused = 1'b1;
    nfo.resp = VGPU_RESP_ERR_INVALID_PARAMETER;
    sfc = '0;
    sfc.valid = 1'b1;
    sfc.hdr = APU_VIRGL_SF_HDR;
    sfc.handle = APU_VIRGL_SURFACE_HANDLE;
    sfc.resource = APU_VIRGL_RES_RT;
    sfc.format = APU_VIRGL_FMT_B8G8R8X8;
    fet = '0;
    fet.valid = 1'b1;
    fet.kind = VGPU_CMD_SUBMIT_3D;
    fet.cmd0 = Cmd0;
    fet.beats = APU_VGPU_EXEC_BEATS;
    qdr = '0;
    qdr.valid = 1'b1;
    qdr.x0 = APU_VIRGL_F32_NEG_ONE;
  endtask

  function automatic logic list_ok(input apu_vgpu_ols_t rec);
    list_ok = rec.valid && rec.count == 32'h0 && rec.capset_id == 32'h0 &&
              rec.resp == VGPU_RESP_OK_NODATA &&
              rec.capset_id != APU_VGPU_CAPSET_VIRGL &&
              rec.resp != VGPU_RESP_ERR_INVALID_PARAMETER;
  endfunction

  task automatic ols_step(input apu_vgpu_ols_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!ols_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    run_base = nread;
    ols_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ols_req = 1'b0;
    while (!ols_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ols_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_olk == '0 &&
          off_cpl == '0);
    if (st == APU_VGPU_OLS_OK) begin
      check("opcode list", list_ok(ols));
      check("read count", nread == n0 + 1 && !order_bad &&
            seen == APU_VGPU_OLS_ADDR);
    end else if (name == "bad beat" || name == "bad count" || name == "bad id") begin
      check("one beat", nread == n0 + 1 && !ols.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), ols_cpl_v);
    ols_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ols_cpl_r = 1'b0;
    while (ols_cpl_v) @(negedge clk);
  endtask

  task automatic olk_step(input apu_vgpu_olk_status_e st, input string name);
    @(negedge clk);
    while (!olk_rdy) @(negedge clk);
    cases++;
    olk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    olk_req = 1'b0;
    while (!olk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), olk_cpl.status == st);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_olk == '0 &&
          off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), olk_cpl_v);
    olk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    olk_cpl_r = 1'b0;
    while (olk_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    ols_req = 1'b0;
    olk_req = 1'b0;
    ols_cpl_r = 1'b0;
    olk_cpl_r = 1'b0;
    rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    nxc = '0;
    cap = '0;
    nfo = '0;
    sfc = '0;
    fet = '0;
    qdr = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && ols == '0 &&
          olk == '0);
    check("profiles keep the list off",
          !ApuOff.OlsEn && !ApuOff.OlkEn &&
          !ApuP1Transport.OlsEn && !ApuP1Transport.OlkEn &&
          !ApuHarness.OlsEn && !ApuHarness.OlkEn &&
          !ApuSchedBoth.OlsEn && !ApuSchedBoth.OlkEn &&
          !ApuBadVirglGrant.OlsEn && !ApuBadVirglGrant.OlkEn &&
          ApuOff.NumCapsets == 0 && !ApuOff.FeatureVirgl);
    cfg = ApuP1Transport;
    cfg.OlsEn = 1'b1;
    cfg.OlkEn = 1'b1;
    check("list does not require virgl", apu_cfg_legal(cfg) &&
          cfg.NumCapsets == 0 && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.OlsEn = 1'b1;
    cfg.OlkEn = 1'b1;
    check("list does not legalize virgl", !apu_cfg_legal(cfg));
    check("list places",
          APU_VGPU_OLS_ADDR == 64'h8800E300 &&
          APU_VGPU_OLS_ADDR != APU_VGPU_NXC_AVAIL &&
          APU_VGPU_OLS_ADDR != APU_VGPU_NXC_DESC &&
          APU_VGPU_OLS_ADDR != APU_VGPU_SUN_IDX &&
          APU_VGPU_CAPSET_VIRGL == 32'd1 &&
          VGPU_RESP_OK_NODATA == 32'h00001100 &&
          VGPU_RESP_ERR_INVALID_PARAMETER == 32'h00001205);

    ols_step(APU_VGPU_OLS_EMPTY, "list empty");
    good_in();
    nxc = '0;
    ols_step(APU_VGPU_OLS_EMPTY, "chain missing");
    good_in();
    fet.beats = 6'd0;
    ols_step(APU_VGPU_OLS_FAULT, "bad identity");
    good_in();
    cap.refused = 1'b0;
    ols_step(APU_VGPU_OLS_FAULT, "capset granted");
    good_in();
    fail_next = 1'b1;
    ols_step(APU_VGPU_OLS_FAULT, "bad beat");
    bad_count = 1'b1;
    ols_step(APU_VGPU_OLS_FAULT, "bad count");
    bad_id = 1'b1;
    ols_step(APU_VGPU_OLS_FAULT, "bad id");
    ols_step(APU_VGPU_OLS_OK, "opcode list");
    ols_step(APU_VGPU_OLS_FAULT, "opcode list again");
    check("opcode list stays", list_ok(ols) && cap.refused &&
          cap.resp == VGPU_RESP_ERR_INVALID_PARAMETER &&
          ols.capset_id != APU_VGPU_CAPSET_VIRGL);
    olk_step(APU_VGPU_OLK_OK, "keep opcode list");
    check("opcode list kept", olk.valid && olk.count == 32'h0 &&
          olk.capset_id == 32'h0 && olk.resp == VGPU_RESP_OK_NODATA);
    olk_step(APU_VGPU_OLK_FAULT, "opcode list keep again");
    check("opcode list keep stays", olk.count == 32'h0 &&
          olk.capset_id == 32'h0);

    pulse_reset();
    check("reset clears", ols == '0 && olk == '0);
    zero_in();
    ols_step(APU_VGPU_OLS_EMPTY, "after reset");
    olk_step(APU_VGPU_OLK_EMPTY, "keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu ols errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_ols cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
