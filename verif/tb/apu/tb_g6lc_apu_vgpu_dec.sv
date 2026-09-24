// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_dec;
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
  logic [APU_VGPU_BUF_ADDRW-1:0] peek_addr;
  logic [31:0] peek_word;

  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v;
  apu_vgpu_dec_cpl_t cpl, off_cpl, snap;
  apu_vgpu_dec_t dec, off_dec;
  logic [APU_VGPU_BUF_ADDRW-1:0] off_peek;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam logic [63:0] BufAddr = 64'h0000_0000_8800_B000;
  localparam logic [31:0] Hdr = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                APU_VIRGL_CREATE_OBJECT};

  assign buf_sub = use_force ? forced : apu_vgpu_sub_t'('0);

  g6lc_apu_vgpu_buf #(.Enable(1'b1)) i_buf (
    .clk_i(clk), .rst_ni, .sub_i(buf_sub),
    .req_valid_i(breq_v), .req_ready_o(breq_rdy),
    .cpl_valid_o(bcpl_v), .cpl_ready_i(bcpl_r), .cpl_o(bcpl), .buf_o(live),
    .peek_addr_i(peek_addr), .peek_word_o(peek_word),
    .rd_valid_o(brd_v), .rd_ready_i(brd_rdy), .rd_addr_o(brd_addr), .rd_len_o(brd_len),
    .rd_rsp_valid_i(brsp_v), .rd_rsp_ready_o(brsp_rdy), .rd_rsp_ok_i(brsp_ok),
    .rd_rsp_addr_i(brsp_addr), .rd_rsp_len_i(brsp_len), .rd_rsp_data_i(brsp_data)
  );
  g6lc_apu_vgpu_dec #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .buf_i(live),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .dec_o(dec),
    .peek_addr_o(peek_addr), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_dec_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .buf_i(live),
    .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .dec_o(off_dec),
    .peek_addr_o(off_peek), .peek_word_i(peek_word)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vgpu dec timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_dec !== '0 ||
        off_peek !== 0)
      $fatal(1, "disabled vgpu dec active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  function automatic logic [APU_VGPU_BEAT_BYTES*8-1:0] surface_beat(
    input logic [31:0] handle
  );
    surface_beat = '0;
    surface_beat[31:0] = Hdr;
    surface_beat[63:32] = handle;
    surface_beat[95:64] = APU_VIRGL_RES_RT;
    surface_beat[127:96] = APU_VIRGL_FMT_B8G8R8X8;
  endfunction

  task automatic load_buf(
    input logic [31:0] size,
    input logic [APU_VGPU_BEAT_BYTES*8-1:0] data,
    input string name
  );
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
    while (!brd_v) @(negedge clk);
    check($sformatf("%s beat", name), brd_addr == BufAddr && brd_len == size);
    brd_rdy = 1;
    @(posedge clk); @(negedge clk); brd_rdy = 0;
    brsp_ok = 1'b1;
    brsp_addr = BufAddr;
    brsp_len = size;
    brsp_data = data;
    brsp_v = 1;
    @(posedge clk); @(negedge clk); brsp_v = 0;
    while (!bcpl_v) @(negedge clk);
    check($sformatf("%s loaded", name), bcpl.status == APU_VGPU_BUF_OK &&
          live.valid && live.size == size);
    @(negedge clk);
    bcpl_r = 1;
    @(posedge clk); @(negedge clk); bcpl_r = 0;
    while (bcpl_v) @(negedge clk);
  endtask

  task automatic dec_step(
    input apu_vgpu_dec_status_e st,
    input string name
  );
    apu_vgpu_dec_cpl_t seen;
    apu_vgpu_dec_t was;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    was = dec;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    while (!cpl_v) @(negedge clk);
    seen = cpl;
    snap = cpl;
    check($sformatf("%s status", name), cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == seen);
    if (st == APU_VGPU_DEC_OK)
      check($sformatf("%s visible", name), dec.valid);
    else
      check($sformatf("%s unchanged", name), dec == was);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
    if (st != APU_VGPU_DEC_OK)
      check($sformatf("%s kept", name), dec == was);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 0;
    breq_v = 0;
    bcpl_r = 0;
    brd_rdy = 0;
    brsp_v = 0;
    req_v = 0;
    cpl_r = 0;
    use_force = 0;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [APU_VGPU_BEAT_BYTES*8-1:0] beat, pad;
    forced = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 && dec == '0);
    check("profiles keep dec off",
          !ApuOff.DecEn && !ApuP1Transport.DecEn && !ApuHarness.DecEn &&
          !ApuSchedBoth.DecEn && !ApuBadVirglGrant.DecEn);
    cfg = ApuP1Transport;
    cfg.DecEn = 1'b1;
    check("dec does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.DecEn = 1'b1;
    check("dec does not legalize virgl", !apu_cfg_legal(cfg));

    dec_step(APU_VGPU_DEC_EMPTY, "empty");

    load_buf(32'd4, '0, "nop load");
    dec_step(APU_VGPU_DEC_OK, "nop");
    check("nop header", dec.valid && !dec.surface && dec.cmd == 8'd0 &&
          dec.obj == 8'd0 && dec.nbody == 16'd0 && dec.next == 32'd4 &&
          dec.handle == 32'h0);

    pulse_reset();
    beat = surface_beat(APU_VIRGL_SURFACE_HANDLE);
    beat[31:0] = Hdr;
    load_buf(32'd4, beat, "short load");
    dec_step(APU_VGPU_DEC_FAULT, "short");
    check("short keeps clear", dec == '0);

    pulse_reset();
    load_buf(32'd24, surface_beat(32'h0), "zero handle load");
    dec_step(APU_VGPU_DEC_FAULT, "zero handle");
    check("zero handle clear", dec == '0);

    pulse_reset();
    load_buf(32'd24, surface_beat(APU_VIRGL_SURFACE_HANDLE), "surface load");
    dec_step(APU_VGPU_DEC_OK, "surface");
    check("surface cmd", dec.valid && dec.surface &&
          dec.cmd == APU_VIRGL_CREATE_OBJECT && dec.obj == APU_VIRGL_OBJ_SURFACE &&
          dec.nbody == APU_VIRGL_SURFACE_DWORDS && dec.next == 32'd24);
    check("surface body", dec.handle == APU_VIRGL_SURFACE_HANDLE &&
          dec.resource_id == APU_VIRGL_RES_RT &&
          dec.format == APU_VIRGL_FMT_B8G8R8X8);
    dec_step(APU_VGPU_DEC_FAULT, "second");
    check("second keeps", dec.surface && dec.handle == APU_VIRGL_SURFACE_HANDLE &&
          dec.next == 32'd24);

    pulse_reset();
    pad = surface_beat(APU_VIRGL_SURFACE_HANDLE);
    pad[255:192] = '1;
    load_buf(32'd32, pad, "pad load");
    dec_step(APU_VGPU_DEC_OK, "pad");
    check("pad stops", dec.surface && dec.next == 32'd24 &&
          dec.handle == APU_VIRGL_SURFACE_HANDLE &&
          dec.format == APU_VIRGL_FMT_B8G8R8X8);

    if (errors != 0) $fatal(1, "APU vgpu dec errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_dec cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
