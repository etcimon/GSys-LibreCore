// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_pre;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_buf_t bufi;
  apu_vgpu_att_t att;
  apu_vgpu_rsp_t rsp;
  logic [31:0] mem [0:255];
  logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr, nfo_peek, cap_peek, scn_peek, flu_peek;
  logic [31:0] peek_word;
  logic use_nfo = 0, use_cap = 0, use_scn = 0, use_flu = 0;

  logic nfo_req = 0, nfo_rdy, nfo_cpl_v, nfo_cpl_r = 0;
  apu_vgpu_nfo_cpl_t nfo_cpl;
  apu_vgpu_nfo_t nfo;
  logic cap_req = 0, cap_rdy, cap_cpl_v, cap_cpl_r = 0;
  apu_vgpu_cap_cpl_t cap_cpl;
  apu_vgpu_cap_t cap;
  logic scn_req = 0, scn_rdy, scn_cpl_v, scn_cpl_r = 0;
  apu_vgpu_scn_cpl_t scn_cpl;
  apu_vgpu_scn_t scn;
  logic flu_req = 0, flu_rdy, flu_cpl_v, flu_cpl_r = 0;
  apu_vgpu_flu_cpl_t flu_cpl, off_cpl;
  apu_vgpu_flu_t flu, off_flu;
  logic off_rdy, off_v;
  logic [APU_VGPU_BUF_ADDRW-1:0] off_peek;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  assign peek_addr = use_flu ? flu_peek : use_scn ? scn_peek :
                     use_cap ? cap_peek : nfo_peek;
  assign peek_word = mem[peek_addr[9:2]];

  g6lc_apu_vgpu_nfo #(.Enable(1'b1)) i_nfo (
    .clk_i(clk), .rst_ni, .buf_i(bufi),
    .req_valid_i(nfo_req), .req_ready_o(nfo_rdy),
    .cpl_valid_o(nfo_cpl_v), .cpl_ready_i(nfo_cpl_r), .cpl_o(nfo_cpl), .nfo_o(nfo),
    .peek_addr_o(nfo_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_cap #(.Enable(1'b1)) i_cap (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .nfo_i(nfo),
    .req_valid_i(cap_req), .req_ready_o(cap_rdy),
    .cpl_valid_o(cap_cpl_v), .cpl_ready_i(cap_cpl_r), .cpl_o(cap_cpl), .cap_o(cap),
    .peek_addr_o(cap_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_scn #(.Enable(1'b1)) i_scn (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .att_i(att), .rsp_i(rsp),
    .req_valid_i(scn_req), .req_ready_o(scn_rdy),
    .cpl_valid_o(scn_cpl_v), .cpl_ready_i(scn_cpl_r), .cpl_o(scn_cpl), .scn_o(scn),
    .peek_addr_o(scn_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_flu #(.Enable(1'b1)) i_flu (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .scn_i(scn),
    .req_valid_i(flu_req), .req_ready_o(flu_rdy),
    .cpl_valid_o(flu_cpl_v), .cpl_ready_i(flu_cpl_r), .cpl_o(flu_cpl), .flu_o(flu),
    .peek_addr_o(flu_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_flu_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .buf_i(bufi), .scn_i(scn),
    .req_valid_i(flu_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(flu_cpl_r), .cpl_o(off_cpl), .flu_o(off_flu),
    .peek_addr_o(off_peek), .peek_word_i(peek_word)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "APU vgpu pre timeout case=%0d", cases); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  function automatic logic [31:0] cap_word(input int unsigned w);
    int unsigned rel;
    cap_word = 32'h0;
    if (w < 8) begin
      if (w == 0) cap_word = VGPU_CMD_GET_CAPSET_INFO;
    end else if (w < 16) begin
      rel = w - 8;
      if (rel == 0) cap_word = VGPU_CMD_GET_CAPSET;
      else if (rel == 6) cap_word = APU_VGPU_CAPSET_VIRGL;
      else if (rel == 7) cap_word = APU_VGPU_CAPSET_VERSION;
    end
  endfunction

  function automatic logic [31:0] scn_word(input int unsigned w);
    int unsigned rel;
    scn_word = 32'h0;
    if (w < 12) begin
      if (w == 0) scn_word = VGPU_CMD_SET_SCANOUT;
      else if (w == 8) scn_word = APU_VGPU_RT_W;
      else if (w == 9) scn_word = APU_VGPU_RT_H;
      else if (w == 11) scn_word = APU_VGPU_RES_RT;
    end else if (w < 24) begin
      rel = w - 12;
      if (rel == 0) scn_word = VGPU_CMD_RESOURCE_FLUSH;
      else if (rel == 8) scn_word = APU_VGPU_RT_W;
      else if (rel == 9) scn_word = APU_VGPU_RT_H;
      else if (rel == 10) scn_word = APU_VGPU_RES_RT;
    end
  endfunction

  task automatic load_cap;
    for (int i = 0; i < 16; i++) mem[i] = cap_word(i);
  endtask

  task automatic load_scn;
    for (int i = 0; i < 24; i++) mem[i] = scn_word(i);
  endtask

  task automatic set_buf(input logic valid, input logic [31:0] size);
    bufi = '0;
    bufi.valid = valid;
    bufi.size = size;
    bufi.buf_addr = 64'h2;
  endtask

  task automatic scene_ready;
    att = '0;
    att.rt = 1'b1;
    att.vbo = 1'b1;
    att.scan = 1'b1;
    att.next = APU_VGPU_CTL_END;
    rsp = '0;
    rsp.valid = 1'b1;
    rsp.addr = APU_VGPU_RSP_ADDR;
    rsp.ctx_id = APU_VGPU_CTX_ID;
    rsp.fence = APU_VGPU_SCENE_FENCE;
  endtask

  task automatic nfo_step(input apu_vgpu_nfo_status_e st, input string name);
    @(negedge clk);
    while (!nfo_rdy) @(negedge clk);
    cases++;
    use_nfo = 1'b1;
    use_cap = 1'b0;
    use_scn = 1'b0;
    use_flu = 1'b0;
    nfo_req = 1;
    @(posedge clk); @(negedge clk); nfo_req = 0;
    while (!nfo_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), nfo_cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), nfo_cpl_v);
    nfo_cpl_r = 1;
    @(posedge clk); @(negedge clk); nfo_cpl_r = 0;
    while (nfo_cpl_v) @(negedge clk);
    use_nfo = 1'b0;
  endtask

  task automatic cap_step(input apu_vgpu_cap_status_e st, input string name);
    @(negedge clk);
    while (!cap_rdy) @(negedge clk);
    cases++;
    use_cap = 1'b1;
    use_nfo = 1'b0;
    cap_req = 1;
    @(posedge clk); @(negedge clk); cap_req = 0;
    while (!cap_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), cap_cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), cap_cpl_v);
    cap_cpl_r = 1;
    @(posedge clk); @(negedge clk); cap_cpl_r = 0;
    while (cap_cpl_v) @(negedge clk);
    use_cap = 1'b0;
  endtask

  task automatic scn_step(input apu_vgpu_scn_status_e st, input string name);
    @(negedge clk);
    while (!scn_rdy) @(negedge clk);
    cases++;
    use_scn = 1'b1;
    use_nfo = 1'b0;
    use_cap = 1'b0;
    scn_req = 1;
    @(posedge clk); @(negedge clk); scn_req = 0;
    while (!scn_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), scn_cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), scn_cpl_v);
    scn_cpl_r = 1;
    @(posedge clk); @(negedge clk); scn_cpl_r = 0;
    while (scn_cpl_v) @(negedge clk);
    use_scn = 1'b0;
  endtask

  task automatic flu_step(input apu_vgpu_flu_status_e st, input string name);
    @(negedge clk);
    while (!flu_rdy) @(negedge clk);
    cases++;
    use_flu = 1'b1;
    use_scn = 1'b0;
    flu_req = 1;
    @(posedge clk); @(negedge clk); flu_req = 0;
    while (!flu_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), flu_cpl.status == st);
    check($sformatf("%s off quiet", name), off_rdy == 0 && off_v == 0 && off_flu == '0);
    @(negedge clk);
    check($sformatf("%s held", name), flu_cpl_v);
    flu_cpl_r = 1;
    @(posedge clk); @(negedge clk); flu_cpl_r = 0;
    while (flu_cpl_v) @(negedge clk);
    use_flu = 1'b0;
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    nfo_req = 0;
    cap_req = 0;
    scn_req = 0;
    flu_req = 0;
    nfo_cpl_r = 0;
    cap_cpl_r = 0;
    scn_cpl_r = 0;
    flu_cpl_r = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    bufi = '0;
    att = '0;
    rsp = '0;
    for (int i = 0; i < 256; i++) mem[i] = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && flu == '0 && nfo == '0);
    check("profiles keep pre off",
          !ApuOff.NfoEn && !ApuOff.CapEn && !ApuOff.ScnEn && !ApuOff.FluEn &&
          !ApuP1Transport.NfoEn && !ApuP1Transport.CapEn && !ApuP1Transport.ScnEn &&
          !ApuP1Transport.FluEn &&
          !ApuHarness.NfoEn && !ApuHarness.CapEn && !ApuHarness.ScnEn && !ApuHarness.FluEn &&
          !ApuSchedBoth.NfoEn && !ApuSchedBoth.CapEn && !ApuSchedBoth.ScnEn &&
          !ApuSchedBoth.FluEn &&
          !ApuBadVirglGrant.NfoEn && !ApuBadVirglGrant.CapEn &&
          !ApuBadVirglGrant.ScnEn && !ApuBadVirglGrant.FluEn);
    cfg = ApuP1Transport;
    cfg.NfoEn = 1'b1;
    cfg.CapEn = 1'b1;
    cfg.ScnEn = 1'b1;
    cfg.FluEn = 1'b1;
    check("pre does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.NfoEn = 1'b1;
    cfg.CapEn = 1'b1;
    cfg.ScnEn = 1'b1;
    cfg.FluEn = 1'b1;
    check("pre does not legalize virgl", !apu_cfg_legal(cfg));

    set_buf(1'b0, 32'd0);
    nfo_step(APU_VGPU_NFO_EMPTY, "nfo empty");
    set_buf(1'b1, 32'd16);
    nfo_step(APU_VGPU_NFO_FAULT, "nfo short");
    check("nfo short keeps", !nfo.refused);
    load_cap();
    set_buf(1'b1, APU_VGPU_CAP_END);
    mem[6] = 32'd1;
    nfo_step(APU_VGPU_NFO_FAULT, "nfo index");
    check("index keeps", !nfo.refused);
    mem[6] = cap_word(6);
    nfo_step(APU_VGPU_NFO_OK, "nfo");
    check("nfo refusal", nfo.refused && nfo.resp == VGPU_RESP_ERR_INVALID_PARAMETER &&
          nfo.next == APU_VGPU_NFO_BYTES);
    nfo_step(APU_VGPU_NFO_FAULT, "nfo again");
    check("nfo kept", nfo.refused && nfo.resp == VGPU_RESP_ERR_INVALID_PARAMETER);

    pulse_reset();
    check("reset clears nfo", nfo == '0 && cap == '0);
    load_cap();
    set_buf(1'b1, APU_VGPU_CAP_END);
    cap_step(APU_VGPU_CAP_EMPTY, "cap early");
    nfo_step(APU_VGPU_NFO_OK, "nfo for cap");
    mem[15] = 32'd2;
    cap_step(APU_VGPU_CAP_FAULT, "cap version");
    check("version keeps", !cap.refused);
    mem[15] = cap_word(15);
    cap_step(APU_VGPU_CAP_OK, "cap");
    check("cap refusal", cap.refused && cap.resp == VGPU_RESP_ERR_INVALID_PARAMETER &&
          cap.next == APU_VGPU_CAP_END);
    cap_step(APU_VGPU_CAP_FAULT, "cap again");
    check("cap kept", cap.refused);

    pulse_reset();
    load_scn();
    set_buf(1'b1, APU_VGPU_SCN_END);
    att = '0;
    rsp = '0;
    scn_step(APU_VGPU_SCN_EMPTY, "scn empty");
    scene_ready();
    rsp.valid = 1'b0;
    scn_step(APU_VGPU_SCN_EMPTY, "scn before rsp");
    scene_ready();
    mem[8] = 32'd64;
    mem[9] = 32'd64;
    scn_step(APU_VGPU_SCN_FAULT, "scn 64");
    check("64 keeps", !scn.valid);
    mem[8] = scn_word(8);
    mem[9] = scn_word(9);
    scn_step(APU_VGPU_SCN_OK, "scn");
    check("scn record", scn.valid && scn.scanout_id == 32'h0 &&
          scn.resource_id == APU_VGPU_RES_RT && scn.width == APU_VGPU_RT_W &&
          scn.height == APU_VGPU_RT_H && scn.next == APU_VGPU_SCN_BYTES);
    scn_step(APU_VGPU_SCN_FAULT, "scn again");
    check("scn kept", scn.valid && scn.resource_id == APU_VGPU_RES_RT);

    pulse_reset();
    load_scn();
    set_buf(1'b1, APU_VGPU_SCN_END);
    scene_ready();
    flu_step(APU_VGPU_FLU_EMPTY, "flu early");
    scn_step(APU_VGPU_SCN_OK, "scn for flu");
    mem[22] = 32'd9;
    flu_step(APU_VGPU_FLU_FAULT, "flu id");
    check("flu kept clear", !flu.valid);
    mem[22] = scn_word(22);
    flu_step(APU_VGPU_FLU_OK, "flu");
    check("flu record", flu.valid && flu.resource_id == APU_VGPU_RES_RT &&
          flu.width == APU_VGPU_RT_W && flu.height == APU_VGPU_RT_H &&
          flu.next == APU_VGPU_SCN_END);
    flu_step(APU_VGPU_FLU_FAULT, "flu again");
    check("flu kept", flu.valid && flu.next == APU_VGPU_SCN_END);

    pulse_reset();
    check("reset clears flu", flu == '0 && scn == '0 && cap == '0);
    if (errors != 0) $fatal(1, "APU vgpu pre errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_pre cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
