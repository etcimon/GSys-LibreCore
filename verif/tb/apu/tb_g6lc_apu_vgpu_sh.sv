// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_sh;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0;
  logic breq_v = 0, breq_rdy, bcpl_v, bcpl_r = 0;
  logic brd_v, brd_rdy = 0, brsp_rdy;
  logic [63:0] brd_addr;
  logic [31:0] brd_len;
  logic brsp_v = 0, brsp_ok = 0;
  logic [63:0] brsp_addr = '0;
  logic [31:0] brsp_len = '0;
  logic [APU_VGPU_BEAT_BYTES*8-1:0] brsp_data = '0;
  logic use_force = 0;
  apu_vgpu_sub_t forced, buf_sub;
  apu_vgpu_buf_cpl_t bcpl;
  apu_vgpu_buf_t live;
  logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr, dec_peek, sh_peek, off_peek;
  logic [31:0] peek_word;
  logic use_sh = 0;

  logic dreq_v = 0, dreq_rdy, dcpl_v, dcpl_r = 0;
  apu_vgpu_dec_cpl_t dcpl;
  apu_vgpu_dec_t dec;

  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v;
  apu_vgpu_sh_cpl_t cpl, off_cpl;
  apu_vgpu_sh_t sh, off_sh;
  int errors = 0, checks = 0, cycles = 0, cases = 0, img = 0;

  localparam logic [63:0] BufAddr = 64'h0000_0000_8800_B000;
  localparam logic [31:0] SurfHdr = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                    APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] VsOff = 32'd125;
  localparam logic [31:0] VsTokens = 32'd300;
  localparam logic [31:0] Vert = 32'h5452_4556;
  localparam logic [15:0] VsBody = 16'd37;
  localparam logic [31:0] VsHdr = {VsBody, APU_VIRGL_OBJ_SHADER, APU_VIRGL_CREATE_OBJECT};

  assign buf_sub = use_force ? forced : apu_vgpu_sub_t'('0);
  assign peek_addr = use_sh ? sh_peek : dec_peek;

  g6lc_apu_vgpu_buf #(.Enable(1'b1)) i_buf (
    .clk_i(clk), .rst_ni, .sub_i(buf_sub),
    .req_valid_i(breq_v), .req_ready_o(breq_rdy),
    .cpl_valid_o(bcpl_v), .cpl_ready_i(bcpl_r), .cpl_o(bcpl), .buf_o(live),
    .peek_addr_i(peek_addr), .peek_word_o(peek_word),
    .rd_valid_o(brd_v), .rd_ready_i(brd_rdy), .rd_addr_o(brd_addr), .rd_len_o(brd_len),
    .rd_rsp_valid_i(brsp_v), .rd_rsp_ready_o(brsp_rdy), .rd_rsp_ok_i(brsp_ok),
    .rd_rsp_addr_i(brsp_addr), .rd_rsp_len_i(brsp_len), .rd_rsp_data_i(brsp_data)
  );
  g6lc_apu_vgpu_dec #(.Enable(1'b1)) i_dec (
    .clk_i(clk), .rst_ni, .buf_i(live),
    .req_valid_i(dreq_v), .req_ready_o(dreq_rdy),
    .cpl_valid_o(dcpl_v), .cpl_ready_i(dcpl_r), .cpl_o(dcpl), .dec_o(dec),
    .peek_addr_o(dec_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_sh #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .buf_i(live), .dec_i(dec),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .sh_o(sh),
    .peek_addr_o(sh_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_sh_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .buf_i(live), .dec_i(dec),
    .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .sh_o(off_sh),
    .peek_addr_o(off_peek), .peek_word_i(peek_word)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vgpu sh timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_sh !== '0 || off_peek !== 0)
      $fatal(1, "disabled vgpu sh active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  function automatic logic [31:0] word_of(input logic [31:0] di);
    word_of = '0;
    if (img != 0 && di == 0) word_of = SurfHdr;
    else if (img != 0 && di == 1) word_of = APU_VIRGL_SURFACE_HANDLE;
    else if (img != 0 && di == 2) word_of = APU_VIRGL_RES_RT;
    else if (img != 0 && di == 3) word_of = APU_VIRGL_FMT_B8G8R8X8;
    else if (img == 1 && di == 6) word_of = {16'd6, APU_VIRGL_OBJ_SHADER, APU_VIRGL_CREATE_OBJECT};
    else if (img == 1 && di == 7) word_of = APU_VIRGL_VS_HANDLE;
    else if (img == 1 && di == 9) word_of = 32'd8;
    else if (img == 1 && di == 10) word_of = VsTokens;
    else if (img == 2 && di == 6) word_of = VsHdr;
    else if (img == 2 && di == 7) word_of = APU_VIRGL_VS_HANDLE;
    else if (img == 2 && di == 9) word_of = VsOff;
    else if (img == 2 && di == 10) word_of = VsTokens;
    else if (img == 2 && di == 12) word_of = Vert;
  endfunction

  function automatic logic [7:0] byte_of(input logic [31:0] a);
    logic [31:0] w;
    w = word_of(a >> 2);
    if (a[1:0] == 2'd0) byte_of = w[7:0];
    else if (a[1:0] == 2'd1) byte_of = w[15:8];
    else if (a[1:0] == 2'd2) byte_of = w[23:16];
    else byte_of = w[31:24];
  endfunction

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] beat_of(
    input logic [31:0] off, input logic [31:0] n
  );
    beat_of = '0;
    for (int k = 0; k < APU_VGPU_BEAT_BYTES; k++) begin
      if (32'(k) < n)
        beat_of[k*8 +: 8] = byte_of(off + 32'(k));
    end
  endfunction

  function automatic logic [31:0] beat_n(
    input logic [31:0] off, input logic [31:0] total
  );
    logic [31:0] remain;
    remain = total - off;
    beat_n = remain > APU_VGPU_BEAT_BYTES ? APU_VGPU_BEAT_BYTES : remain;
  endfunction

  task automatic load_buf(input logic [31:0] size, input string name);
    logic [31:0] off, n;
    @(negedge clk);
    while (!breq_rdy) @(negedge clk);
    cases++;
    forced = '0;
    forced.valid = 1'b1;
    forced.ctx_id = 32'd1;
    forced.size = size;
    forced.buf_addr = BufAddr;
    use_force = 1'b1;
    breq_v = 1;
    @(posedge clk); @(negedge clk); breq_v = 0;
    off = '0;
    while (off < size) begin
      while (!brd_v) @(negedge clk);
      n = beat_n(off, size);
      check($sformatf("%s beat %0d", name, off), brd_addr == BufAddr + 64'(off) &&
            brd_len == n);
      brd_rdy = 1;
      @(posedge clk); @(negedge clk); brd_rdy = 0;
      brsp_ok = 1'b1;
      brsp_addr = BufAddr + 64'(off);
      brsp_len = n;
      brsp_data = beat_of(off, n);
      brsp_v = 1;
      @(posedge clk); @(negedge clk); brsp_v = 0;
      off = off + n;
    end
    while (!bcpl_v) @(negedge clk);
    check($sformatf("%s loaded", name), bcpl.status == APU_VGPU_BUF_OK &&
          live.valid && live.size == size);
    @(negedge clk);
    bcpl_r = 1;
    @(posedge clk); @(negedge clk); bcpl_r = 0;
    while (bcpl_v) @(negedge clk);
  endtask

  task automatic dec_step(input apu_vgpu_dec_status_e st, input string name);
    @(negedge clk);
    while (!dreq_rdy) @(negedge clk);
    cases++;
    use_sh = 1'b0;
    dreq_v = 1;
    @(posedge clk); @(negedge clk); dreq_v = 0;
    while (!dcpl_v) @(negedge clk);
    check($sformatf("%s status", name), dcpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), dcpl_v && !dreq_rdy);
    dcpl_r = 1;
    @(posedge clk); @(negedge clk); dcpl_r = 0;
    while (dcpl_v) @(negedge clk);
  endtask

  task automatic sh_step(input apu_vgpu_sh_status_e st, input string name);
    apu_vgpu_sh_cpl_t seen;
    apu_vgpu_sh_t was;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    was = sh;
    use_sh = 1'b1;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    while (!cpl_v) @(negedge clk);
    seen = cpl;
    check($sformatf("%s status", name), cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == seen);
    if (st != APU_VGPU_SH_OK)
      check($sformatf("%s unchanged", name), sh == was);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
    if (st != APU_VGPU_SH_OK)
      check($sformatf("%s kept", name), sh == was);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    breq_v = 0;
    bcpl_r = 0;
    brd_rdy = 0;
    brsp_v = 0;
    dreq_v = 0;
    dcpl_r = 0;
    req_v = 0;
    cpl_r = 0;
    use_force = 0;
    use_sh = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    forced = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 && sh == '0);
    check("profiles keep sh off",
          !ApuOff.ShEn && !ApuP1Transport.ShEn && !ApuHarness.ShEn &&
          !ApuSchedBoth.ShEn && !ApuBadVirglGrant.ShEn);
    cfg = ApuP1Transport;
    cfg.ShEn = 1'b1;
    check("sh does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.ShEn = 1'b1;
    check("sh does not legalize virgl", !apu_cfg_legal(cfg));

    sh_step(APU_VGPU_SH_EMPTY, "empty");

    img = 0;
    load_buf(32'd4, "nop load");
    dec_step(APU_VGPU_DEC_OK, "nop dec");
    sh_step(APU_VGPU_SH_FAULT, "nop");
    check("nop clear", sh == '0 && !dec.surface);

    pulse_reset();
    img = 3;
    load_buf(32'd24, "room load");
    dec_step(APU_VGPU_DEC_OK, "room dec");
    check("room surface", dec.surface && dec.next == 32'd24);
    sh_step(APU_VGPU_SH_FAULT, "no room");
    check("no room clear", sh == '0);

    pulse_reset();
    img = 1;
    load_buf(32'd52, "bad load");
    dec_step(APU_VGPU_DEC_OK, "bad dec");
    sh_step(APU_VGPU_SH_FAULT, "bad length");
    check("bad clear", sh == '0);

    pulse_reset();
    img = 2;
    load_buf(32'd176, "vs load");
    dec_step(APU_VGPU_DEC_OK, "vs dec");
    check("vs surface", dec.surface && dec.next == 32'd24);
    sh_step(APU_VGPU_SH_OK, "vertex");
    check("vertex id", sh.valid && sh.handle == APU_VIRGL_VS_HANDLE &&
          sh.stage == APU_VIRGL_SHADER_VERTEX && sh.offlen == VsOff &&
          sh.tokens == VsTokens);
    check("vertex text", sh.text0 == Vert && sh.text_at == 32'd48 && sh.next == 32'd176);
    sh_step(APU_VGPU_SH_FAULT, "second");
    check("second keeps", sh.valid && sh.handle == APU_VIRGL_VS_HANDLE &&
          sh.text0 == Vert && sh.next == 32'd176);

    if (errors != 0) $fatal(1, "APU vgpu sh errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_sh cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
