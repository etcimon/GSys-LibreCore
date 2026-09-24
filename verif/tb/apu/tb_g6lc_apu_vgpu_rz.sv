// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rz;
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
  logic [APU_VGPU_BUF_ADDRW-1:0] dec_peek, sh_peek, fs_peek, ve_peek, sv_peek;
  logic [APU_VGPU_BUF_ADDRW-1:0] ss_peek, bl_peek, ds_peek, rz_peek, off_peek;
  logic [31:0] peek_word;
  logic use_sh = 0, use_fs = 0, use_ve = 0, use_sv = 0;
  logic use_ss = 0, use_bl = 0, use_ds = 0, use_rz = 0;

  logic dreq_v = 0, dreq_rdy, dcpl_v, dcpl_r = 0;
  apu_vgpu_dec_cpl_t dcpl;
  apu_vgpu_dec_t dec;
  logic sreq_v = 0, sreq_rdy, scpl_v, scpl_r = 0;
  apu_vgpu_sh_cpl_t scpl;
  apu_vgpu_sh_t sh;
  logic freq_v = 0, freq_rdy, fcpl_v, fcpl_r = 0;
  apu_vgpu_sh_cpl_t fcpl;
  apu_vgpu_sh_t frag;
  logic ereq_v = 0, ereq_rdy, ecpl_v, ecpl_r = 0;
  apu_vgpu_ve_cpl_t ecpl;
  apu_vgpu_ve_t elems;
  logic vreq_v = 0, vreq_rdy, vcpl_v, vcpl_r = 0;
  apu_vgpu_sv_cpl_t vcpl;
  apu_vgpu_sv_t view;
  logic treq_v = 0, treq_rdy, tcpl_v, tcpl_r = 0;
  apu_vgpu_ss_cpl_t tcpl;
  apu_vgpu_ss_t sst;
  logic lreq_v = 0, lreq_rdy, lcpl_v, lcpl_r = 0;
  apu_vgpu_bl_cpl_t lcpl;
  apu_vgpu_bl_t blend;
  logic ureq_v = 0, ureq_rdy, ucpl_v, ucpl_r = 0;
  apu_vgpu_ds_cpl_t ucpl;
  apu_vgpu_ds_t dsa;

  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic off_rdy, off_v;
  apu_vgpu_rz_cpl_t cpl, off_cpl;
  apu_vgpu_rz_t rast, off_rast;
  int errors = 0, checks = 0, cycles = 0, cases = 0, img = 0;

  localparam logic [63:0] BufAddr = 64'h0000_0000_8800_B000;
  localparam logic [31:0] SurfHdr = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                    APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] VsOff = 32'd125;
  localparam logic [31:0] FsOff = 32'd140;
  localparam logic [31:0] Tokens = 32'd300;
  localparam logic [31:0] Vert = 32'h5452_4556;
  localparam logic [31:0] FragW = 32'h4741_5246;
  localparam logic [15:0] VsBody = 16'd37;
  localparam logic [15:0] FsBody = 16'd40;
  localparam logic [31:0] VsHdr = {VsBody, APU_VIRGL_OBJ_SHADER, APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] FsHdr = {FsBody, APU_VIRGL_OBJ_SHADER, APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] VeHdr = {16'd9, APU_VIRGL_OBJ_VERTEX_ELEMENTS, APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] SvHdr = {16'd6, APU_VIRGL_OBJ_SAMPLER_VIEW, APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] SvFmt = {APU_VIRGL_TARGET_2D, 24'(APU_VIRGL_FMT_B8G8R8X8)};
  localparam logic [31:0] SsHdr = {16'd9, APU_VIRGL_OBJ_SAMPLER_STATE, APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] BlHdr = {16'd11, APU_VIRGL_OBJ_BLEND, APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] DsHdr = {16'd5, APU_VIRGL_OBJ_DSA, APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] RzHdr = {16'd9, APU_VIRGL_OBJ_RASTERIZER, APU_VIRGL_CREATE_OBJECT};

  assign buf_sub = use_force ? forced : apu_vgpu_sub_t'('0);
  assign peek_addr = use_rz ? rz_peek : use_ds ? ds_peek : use_bl ? bl_peek :
                     use_ss ? ss_peek : use_sv ? sv_peek : use_ve ? ve_peek :
                     use_fs ? fs_peek : use_sh ? sh_peek : dec_peek;

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
  g6lc_apu_vgpu_sh #(.Enable(1'b1)) i_sh (
    .clk_i(clk), .rst_ni, .buf_i(live), .dec_i(dec),
    .req_valid_i(sreq_v), .req_ready_o(sreq_rdy),
    .cpl_valid_o(scpl_v), .cpl_ready_i(scpl_r), .cpl_o(scpl), .sh_o(sh),
    .peek_addr_o(sh_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_fs #(.Enable(1'b1)) i_fs (
    .clk_i(clk), .rst_ni, .buf_i(live), .sh_i(sh),
    .req_valid_i(freq_v), .req_ready_o(freq_rdy),
    .cpl_valid_o(fcpl_v), .cpl_ready_i(fcpl_r), .cpl_o(fcpl), .fs_o(frag),
    .peek_addr_o(fs_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_ve #(.Enable(1'b1)) i_ve (
    .clk_i(clk), .rst_ni, .buf_i(live), .fs_i(frag),
    .req_valid_i(ereq_v), .req_ready_o(ereq_rdy),
    .cpl_valid_o(ecpl_v), .cpl_ready_i(ecpl_r), .cpl_o(ecpl), .ve_o(elems),
    .peek_addr_o(ve_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_sv #(.Enable(1'b1)) i_sv (
    .clk_i(clk), .rst_ni, .buf_i(live), .ve_i(elems),
    .req_valid_i(vreq_v), .req_ready_o(vreq_rdy),
    .cpl_valid_o(vcpl_v), .cpl_ready_i(vcpl_r), .cpl_o(vcpl), .sv_o(view),
    .peek_addr_o(sv_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_ss #(.Enable(1'b1)) i_ss (
    .clk_i(clk), .rst_ni, .buf_i(live), .sv_i(view),
    .req_valid_i(treq_v), .req_ready_o(treq_rdy),
    .cpl_valid_o(tcpl_v), .cpl_ready_i(tcpl_r), .cpl_o(tcpl), .ss_o(sst),
    .peek_addr_o(ss_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_bl #(.Enable(1'b1)) i_bl (
    .clk_i(clk), .rst_ni, .buf_i(live), .ss_i(sst),
    .req_valid_i(lreq_v), .req_ready_o(lreq_rdy),
    .cpl_valid_o(lcpl_v), .cpl_ready_i(lcpl_r), .cpl_o(lcpl), .bl_o(blend),
    .peek_addr_o(bl_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_ds #(.Enable(1'b1)) i_ds (
    .clk_i(clk), .rst_ni, .buf_i(live), .bl_i(blend),
    .req_valid_i(ureq_v), .req_ready_o(ureq_rdy),
    .cpl_valid_o(ucpl_v), .cpl_ready_i(ucpl_r), .cpl_o(ucpl), .ds_o(dsa),
    .peek_addr_o(ds_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_rz #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .buf_i(live), .ds_i(dsa),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .rz_o(rast),
    .peek_addr_o(rz_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_rz_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .buf_i(live), .ds_i(dsa),
    .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .rz_o(off_rast),
    .peek_addr_o(off_peek), .peek_word_i(peek_word)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #800000; $fatal(1, "vgpu rz timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_rast !== '0 || off_peek !== 0)
      $fatal(1, "disabled vgpu rz active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  function automatic logic [31:0] word_of(input logic [31:0] di);
    logic has_chain;
    word_of = '0;
    has_chain = img == 1 || img == 2 || img == 3 || img == 5;
    if (img != 0 && di == 0) word_of = SurfHdr;
    else if (img != 0 && di == 1) word_of = APU_VIRGL_SURFACE_HANDLE;
    else if (img != 0 && di == 2) word_of = APU_VIRGL_RES_RT;
    else if (img != 0 && di == 3) word_of = APU_VIRGL_FMT_B8G8R8X8;
    else if (has_chain && di == 6) word_of = VsHdr;
    else if (has_chain && di == 7) word_of = APU_VIRGL_VS_HANDLE;
    else if (has_chain && di == 9) word_of = VsOff;
    else if (has_chain && di == 10) word_of = Tokens;
    else if (has_chain && di == 12) word_of = Vert;
    else if (has_chain && di == 44) word_of = FsHdr;
    else if (has_chain && di == 45) word_of = APU_VIRGL_FS_HANDLE;
    else if (has_chain && di == 46) word_of = 32'(APU_VIRGL_SHADER_FRAGMENT);
    else if (has_chain && di == 47) word_of = FsOff;
    else if (has_chain && di == 48) word_of = Tokens;
    else if (has_chain && di == 50) word_of = FragW;
    else if (has_chain && di == 85) word_of = VeHdr;
    else if (has_chain && di == 86) word_of = APU_VIRGL_VE_HANDLE;
    else if (has_chain && di == 90) word_of = APU_VIRGL_FMT_R32G32B32A32_FLOAT;
    else if (has_chain && di == 91) word_of = 32'd16;
    else if (has_chain && di == 94) word_of = APU_VIRGL_FMT_R32G32_FLOAT;
    else if (has_chain && di == 95) word_of = SvHdr;
    else if (has_chain && di == 96) word_of = APU_VIRGL_SV_HANDLE;
    else if (has_chain && di == 97) word_of = APU_VIRGL_RES_SCAN;
    else if (has_chain && di == 98) word_of = SvFmt;
    else if (has_chain && di == 101) word_of = APU_VIRGL_SWIZZLE_IDENTITY;
    else if (has_chain && di == 102) word_of = SsHdr;
    else if (has_chain && di == 103) word_of = APU_VIRGL_SS_HANDLE;
    else if (has_chain && di == 104) word_of = APU_VIRGL_SSTATE_S0;
    else if (has_chain && di == 107) word_of = APU_VIRGL_SSTATE_MAX_LOD;
    else if (has_chain && di == 112) word_of = BlHdr;
    else if (has_chain && di == 113) word_of = APU_VIRGL_BL_HANDLE;
    else if (has_chain && di == 116) word_of = APU_VIRGL_BLEND_S2;
    else if (has_chain && di == 124) word_of = DsHdr;
    else if (has_chain && di == 125) word_of = APU_VIRGL_DS_HANDLE;
    else if (img == 1 && di == 130)
      word_of = {16'd8, APU_VIRGL_OBJ_RASTERIZER, APU_VIRGL_CREATE_OBJECT};
    else if ((img == 2 || img == 3) && di == 130) word_of = RzHdr;
    else if ((img == 2 || img == 3) && di == 131) word_of = APU_VIRGL_RZ_HANDLE;
    else if (img == 2 && di == 132) word_of = 32'd1;
  endfunction

  function automatic logic [7:0] byte_of(input logic [31:0] a);
    logic [31:0] w;
    w = word_of(a >> 2);
    if (a[1:0] == 2'd0) byte_of = w[7:0];
    else if (a[1:0] == 2'd1) byte_of = w[15:8];
    else if (a[1:0] == 2'd2) byte_of = w[23:16];
    else byte_of = w[31:24];
  endfunction

  function automatic logic [31:0] beat_n(input logic [31:0] off, input logic [31:0] total);
    logic [31:0] remain;
    remain = total - off;
    beat_n = remain > APU_VGPU_BEAT_BYTES ? APU_VGPU_BEAT_BYTES : remain;
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

  task automatic quiet_peek;
    use_sh = 1'b0;
    use_fs = 1'b0;
    use_ve = 1'b0;
    use_sv = 1'b0;
    use_ss = 1'b0;
    use_bl = 1'b0;
    use_ds = 1'b0;
    use_rz = 1'b0;
  endtask

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
    quiet_peek();
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
    check($sformatf("%s loaded", name), bcpl.status == APU_VGPU_BUF_OK && live.size == size);
    @(negedge clk);
    bcpl_r = 1;
    @(posedge clk); @(negedge clk); bcpl_r = 0;
    while (bcpl_v) @(negedge clk);
  endtask

  task automatic dec_step(input string name);
    @(negedge clk);
    while (!dreq_rdy) @(negedge clk);
    cases++;
    quiet_peek();
    dreq_v = 1;
    @(posedge clk); @(negedge clk); dreq_v = 0;
    while (!dcpl_v) @(negedge clk);
    check($sformatf("%s status", name), dcpl.status == APU_VGPU_DEC_OK && dec.surface);
    @(negedge clk);
    dcpl_r = 1;
    @(posedge clk); @(negedge clk); dcpl_r = 0;
    while (dcpl_v) @(negedge clk);
  endtask

  task automatic sh_step(input apu_vgpu_sh_status_e st, input string name);
    @(negedge clk);
    while (!sreq_rdy) @(negedge clk);
    cases++;
    quiet_peek();
    use_sh = 1'b1;
    sreq_v = 1;
    @(posedge clk); @(negedge clk); sreq_v = 0;
    while (!scpl_v) @(negedge clk);
    check($sformatf("%s status", name), scpl.status == st);
    @(negedge clk);
    scpl_r = 1;
    @(posedge clk); @(negedge clk); scpl_r = 0;
    while (scpl_v) @(negedge clk);
  endtask

  task automatic fs_step(input apu_vgpu_sh_status_e st, input string name);
    @(negedge clk);
    while (!freq_rdy) @(negedge clk);
    cases++;
    quiet_peek();
    use_fs = 1'b1;
    freq_v = 1;
    @(posedge clk); @(negedge clk); freq_v = 0;
    while (!fcpl_v) @(negedge clk);
    check($sformatf("%s status", name), fcpl.status == st);
    @(negedge clk);
    fcpl_r = 1;
    @(posedge clk); @(negedge clk); fcpl_r = 0;
    while (fcpl_v) @(negedge clk);
  endtask

  task automatic ve_step(input apu_vgpu_ve_status_e st, input string name);
    @(negedge clk);
    while (!ereq_rdy) @(negedge clk);
    cases++;
    quiet_peek();
    use_ve = 1'b1;
    ereq_v = 1;
    @(posedge clk); @(negedge clk); ereq_v = 0;
    while (!ecpl_v) @(negedge clk);
    check($sformatf("%s status", name), ecpl.status == st);
    @(negedge clk);
    ecpl_r = 1;
    @(posedge clk); @(negedge clk); ecpl_r = 0;
    while (ecpl_v) @(negedge clk);
  endtask

  task automatic sv_step(input apu_vgpu_sv_status_e st, input string name);
    @(negedge clk);
    while (!vreq_rdy) @(negedge clk);
    cases++;
    quiet_peek();
    use_sv = 1'b1;
    vreq_v = 1;
    @(posedge clk); @(negedge clk); vreq_v = 0;
    while (!vcpl_v) @(negedge clk);
    check($sformatf("%s status", name), vcpl.status == st);
    @(negedge clk);
    vcpl_r = 1;
    @(posedge clk); @(negedge clk); vcpl_r = 0;
    while (vcpl_v) @(negedge clk);
  endtask

  task automatic ss_step(input apu_vgpu_ss_status_e st, input string name);
    @(negedge clk);
    while (!treq_rdy) @(negedge clk);
    cases++;
    quiet_peek();
    use_ss = 1'b1;
    treq_v = 1;
    @(posedge clk); @(negedge clk); treq_v = 0;
    while (!tcpl_v) @(negedge clk);
    check($sformatf("%s status", name), tcpl.status == st);
    @(negedge clk);
    tcpl_r = 1;
    @(posedge clk); @(negedge clk); tcpl_r = 0;
    while (tcpl_v) @(negedge clk);
  endtask

  task automatic bl_step(input apu_vgpu_bl_status_e st, input string name);
    @(negedge clk);
    while (!lreq_rdy) @(negedge clk);
    cases++;
    quiet_peek();
    use_bl = 1'b1;
    lreq_v = 1;
    @(posedge clk); @(negedge clk); lreq_v = 0;
    while (!lcpl_v) @(negedge clk);
    check($sformatf("%s status", name), lcpl.status == st);
    @(negedge clk);
    lcpl_r = 1;
    @(posedge clk); @(negedge clk); lcpl_r = 0;
    while (lcpl_v) @(negedge clk);
  endtask

  task automatic ds_step(input apu_vgpu_ds_status_e st, input string name);
    @(negedge clk);
    while (!ureq_rdy) @(negedge clk);
    cases++;
    quiet_peek();
    use_ds = 1'b1;
    ureq_v = 1;
    @(posedge clk); @(negedge clk); ureq_v = 0;
    while (!ucpl_v) @(negedge clk);
    check($sformatf("%s status", name), ucpl.status == st);
    @(negedge clk);
    ucpl_r = 1;
    @(posedge clk); @(negedge clk); ucpl_r = 0;
    while (ucpl_v) @(negedge clk);
  endtask

  task automatic rz_step(input apu_vgpu_rz_status_e st, input string name);
    apu_vgpu_rz_cpl_t seen;
    apu_vgpu_rz_t was;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    was = rast;
    quiet_peek();
    use_rz = 1'b1;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    while (!cpl_v) @(negedge clk);
    seen = cpl;
    check($sformatf("%s status", name), cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == seen);
    if (st != APU_VGPU_RZ_OK)
      check($sformatf("%s unchanged", name), rast == was);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
    if (st != APU_VGPU_RZ_OK)
      check($sformatf("%s kept", name), rast == was);
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
    sreq_v = 0;
    scpl_r = 0;
    freq_v = 0;
    fcpl_r = 0;
    ereq_v = 0;
    ecpl_r = 0;
    vreq_v = 0;
    vcpl_r = 0;
    treq_v = 0;
    tcpl_r = 0;
    lreq_v = 0;
    lcpl_r = 0;
    ureq_v = 0;
    ucpl_r = 0;
    req_v = 0;
    cpl_r = 0;
    use_force = 0;
    quiet_peek();
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
    check("off stays quiet", off_rdy == 0 && off_v == 0 && req_rdy == 1 && rast == '0);
    check("profiles keep rz off",
          !ApuOff.RzEn && !ApuP1Transport.RzEn && !ApuHarness.RzEn &&
          !ApuSchedBoth.RzEn && !ApuBadVirglGrant.RzEn);
    cfg = ApuP1Transport;
    cfg.RzEn = 1'b1;
    check("rz does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.RzEn = 1'b1;
    check("rz does not legalize virgl", !apu_cfg_legal(cfg));

    rz_step(APU_VGPU_RZ_EMPTY, "empty");

    img = 4;
    load_buf(32'd24, "surf load");
    dec_step("surf dec");
    sh_step(APU_VGPU_SH_FAULT, "surf sh");
    fs_step(APU_VGPU_SH_EMPTY, "surf fs");
    ve_step(APU_VGPU_VE_EMPTY, "surf ve");
    sv_step(APU_VGPU_SV_EMPTY, "surf sv");
    ss_step(APU_VGPU_SS_EMPTY, "surf ss");
    bl_step(APU_VGPU_BL_EMPTY, "surf bl");
    ds_step(APU_VGPU_DS_EMPTY, "surf ds");
    rz_step(APU_VGPU_RZ_EMPTY, "before dsa");
    check("before clear", rast == '0);

    pulse_reset();
    img = 5;
    load_buf(32'd520, "room load");
    dec_step("room dec");
    sh_step(APU_VGPU_SH_OK, "room sh");
    fs_step(APU_VGPU_SH_OK, "room fs");
    ve_step(APU_VGPU_VE_OK, "room ve");
    sv_step(APU_VGPU_SV_OK, "room sv");
    ss_step(APU_VGPU_SS_OK, "room ss");
    bl_step(APU_VGPU_BL_OK, "room bl");
    ds_step(APU_VGPU_DS_OK, "room ds");
    check("dsa parked", dsa.valid && dsa.next == 32'd520 &&
          dsa.handle == APU_VIRGL_DS_HANDLE);
    rz_step(APU_VGPU_RZ_FAULT, "no room");
    check("no room clear", rast == '0);

    pulse_reset();
    img = 1;
    load_buf(32'd556, "count load");
    dec_step("count dec");
    sh_step(APU_VGPU_SH_OK, "count sh");
    fs_step(APU_VGPU_SH_OK, "count fs");
    ve_step(APU_VGPU_VE_OK, "count ve");
    sv_step(APU_VGPU_SV_OK, "count sv");
    ss_step(APU_VGPU_SS_OK, "count ss");
    bl_step(APU_VGPU_BL_OK, "count bl");
    ds_step(APU_VGPU_DS_OK, "count ds");
    rz_step(APU_VGPU_RZ_FAULT, "bad count");
    check("bad count clear", rast == '0);

    pulse_reset();
    img = 2;
    load_buf(32'd560, "cull load");
    dec_step("cull dec");
    sh_step(APU_VGPU_SH_OK, "cull sh");
    fs_step(APU_VGPU_SH_OK, "cull fs");
    ve_step(APU_VGPU_VE_OK, "cull ve");
    sv_step(APU_VGPU_SV_OK, "cull sv");
    ss_step(APU_VGPU_SS_OK, "cull ss");
    bl_step(APU_VGPU_BL_OK, "cull bl");
    ds_step(APU_VGPU_DS_OK, "cull ds");
    rz_step(APU_VGPU_RZ_FAULT, "cull set");
    check("cull set clear", rast == '0);

    pulse_reset();
    img = 3;
    load_buf(32'd560, "rast load");
    dec_step("rast dec");
    sh_step(APU_VGPU_SH_OK, "rast sh");
    fs_step(APU_VGPU_SH_OK, "rast fs");
    ve_step(APU_VGPU_VE_OK, "rast ve");
    sv_step(APU_VGPU_SV_OK, "rast sv");
    ss_step(APU_VGPU_SS_OK, "rast ss");
    bl_step(APU_VGPU_BL_OK, "rast bl");
    ds_step(APU_VGPU_DS_OK, "rast ds");
    rz_step(APU_VGPU_RZ_OK, "rast");
    check("rast id", rast.valid && rast.handle == APU_VIRGL_RZ_HANDLE &&
          rast.next == 32'd560);
    check("dsa stays", dsa.valid && dsa.handle == APU_VIRGL_DS_HANDLE &&
          dsa.next == 32'd520);
    rz_step(APU_VGPU_RZ_FAULT, "second");
    check("second keeps", rast.valid && rast.handle == APU_VIRGL_RZ_HANDLE &&
          rast.next == 32'd560);

    if (errors != 0) $fatal(1, "APU vgpu rz errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rz cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
