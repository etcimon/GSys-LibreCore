// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_veb;
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
  logic [APU_VGPU_BUF_ADDRW-1:0] ss_peek, bl_peek, ds_peek, rz_peek, bb_peek;
  logic [APU_VGPU_BUF_ADDRW-1:0] db_peek, rb_peek, vsb_peek, fsb_peek, veb_peek, off_peek;
  logic [31:0] peek_word;
  logic use_sh = 0, use_fs = 0, use_ve = 0, use_sv = 0, use_ss = 0;
  logic use_bl = 0, use_ds = 0, use_rz = 0, use_bb = 0, use_db = 0, use_rb = 0;
  logic use_vsb = 0, use_fsb = 0, use_veb = 0;

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
  logic zreq_v = 0, zreq_rdy, zcpl_v, zcpl_r = 0;
  apu_vgpu_rz_cpl_t zcpl;
  apu_vgpu_rz_t rast;
  logic mreq_v = 0, mreq_rdy, mcpl_v, mcpl_r = 0;
  apu_vgpu_bb_cpl_t mcpl;
  apu_vgpu_bb_t bound;

  logic nreq_v = 0, nreq_rdy, ncpl_v, ncpl_r = 0;
  apu_vgpu_db_cpl_t ncpl;
  apu_vgpu_db_t dsb;

  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  apu_vgpu_rb_cpl_t cpl;
  apu_vgpu_rb_t rbound;
  logic wreq_v = 0, wreq_rdy, wcpl_v, wcpl_r = 0;
  apu_vgpu_vsb_cpl_t wcpl;
  apu_vgpu_vsb_t vsbound;
  logic kreq_v = 0, kreq_rdy, kcpl_v, kcpl_r = 0;
  apu_vgpu_fsb_cpl_t kcpl;
  apu_vgpu_fsb_t fsbound;
  logic jreq_v = 0, jreq_rdy, jcpl_v, jcpl_r = 0;
  logic off_rdy, off_v;
  apu_vgpu_veb_cpl_t jcpl, off_cpl;
  apu_vgpu_veb_t vebound, off_veb;
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
  localparam logic [31:0] BbHdr = {16'd1, APU_VIRGL_OBJ_BLEND, APU_VIRGL_BIND_OBJECT};
  localparam logic [31:0] DbHdr = {16'd1, APU_VIRGL_OBJ_DSA, APU_VIRGL_BIND_OBJECT};
  localparam logic [31:0] RbHdr = {16'd1, APU_VIRGL_OBJ_RASTERIZER, APU_VIRGL_BIND_OBJECT};
  localparam logic [31:0] VsbHdr = {16'd2, 8'd0, APU_VIRGL_BIND_SHADER};
  localparam logic [31:0] FsbHdr = {16'd2, 8'd0, APU_VIRGL_BIND_SHADER};
  localparam logic [31:0] VebHdr = {16'd1, APU_VIRGL_OBJ_VERTEX_ELEMENTS, APU_VIRGL_BIND_OBJECT};

  assign buf_sub = use_force ? forced : apu_vgpu_sub_t'('0);
  assign peek_addr = use_veb ? veb_peek : use_fsb ? fsb_peek : use_vsb ? vsb_peek :
                     use_rb ? rb_peek :
                     use_db ? db_peek :
                     use_bb ? bb_peek :
                     use_rz ? rz_peek :
                     use_ds ? ds_peek : use_bl ? bl_peek : use_ss ? ss_peek :
                     use_sv ? sv_peek : use_ve ? ve_peek : use_fs ? fs_peek :
                     use_sh ? sh_peek : dec_peek;

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
  g6lc_apu_vgpu_rz #(.Enable(1'b1)) i_rz (
    .clk_i(clk), .rst_ni, .buf_i(live), .ds_i(dsa),
    .req_valid_i(zreq_v), .req_ready_o(zreq_rdy),
    .cpl_valid_o(zcpl_v), .cpl_ready_i(zcpl_r), .cpl_o(zcpl), .rz_o(rast),
    .peek_addr_o(rz_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_bb #(.Enable(1'b1)) i_bb (
    .clk_i(clk), .rst_ni, .buf_i(live), .rz_i(rast),
    .req_valid_i(mreq_v), .req_ready_o(mreq_rdy),
    .cpl_valid_o(mcpl_v), .cpl_ready_i(mcpl_r), .cpl_o(mcpl), .bb_o(bound),
    .peek_addr_o(bb_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_db #(.Enable(1'b1)) i_db (
    .clk_i(clk), .rst_ni, .buf_i(live), .bb_i(bound),
    .req_valid_i(nreq_v), .req_ready_o(nreq_rdy),
    .cpl_valid_o(ncpl_v), .cpl_ready_i(ncpl_r), .cpl_o(ncpl), .db_o(dsb),
    .peek_addr_o(db_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_rb #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .buf_i(live), .db_i(dsb),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .rb_o(rbound),
    .peek_addr_o(rb_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_vsb #(.Enable(1'b1)) i_vsb (
    .clk_i(clk), .rst_ni, .buf_i(live), .rb_i(rbound),
    .req_valid_i(wreq_v), .req_ready_o(wreq_rdy),
    .cpl_valid_o(wcpl_v), .cpl_ready_i(wcpl_r), .cpl_o(wcpl), .vsb_o(vsbound),
    .peek_addr_o(vsb_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_fsb #(.Enable(1'b1)) i_fsb (
    .clk_i(clk), .rst_ni, .buf_i(live), .vsb_i(vsbound),
    .req_valid_i(kreq_v), .req_ready_o(kreq_rdy),
    .cpl_valid_o(kcpl_v), .cpl_ready_i(kcpl_r), .cpl_o(kcpl), .fsb_o(fsbound),
    .peek_addr_o(fsb_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_veb #(.Enable(1'b1)) i_veb (
    .clk_i(clk), .rst_ni, .buf_i(live), .fsb_i(fsbound),
    .req_valid_i(jreq_v), .req_ready_o(jreq_rdy),
    .cpl_valid_o(jcpl_v), .cpl_ready_i(jcpl_r), .cpl_o(jcpl), .veb_o(vebound),
    .peek_addr_o(veb_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_veb_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .buf_i(live), .fsb_i(fsbound),
    .req_valid_i(jreq_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(jcpl_r), .cpl_o(off_cpl), .veb_o(off_veb),
    .peek_addr_o(off_peek), .peek_word_i(peek_word)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "vgpu veb timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_veb !== '0 || off_peek !== 0)
      $fatal(1, "disabled vgpu veb active");
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
    has_chain = img == 1 || img == 2 || img == 3 || img == 5 || img == 6;
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
    else if (has_chain && di == 130) word_of = RzHdr;
    else if (has_chain && di == 131) word_of = APU_VIRGL_RZ_HANDLE;
    else if (has_chain && di == 140) word_of = BbHdr;
    else if (has_chain && di == 141) word_of = APU_VIRGL_BL_HANDLE;
    else if (has_chain && di == 142) word_of = DbHdr;
    else if (has_chain && di == 143) word_of = APU_VIRGL_DS_HANDLE;
    else if (has_chain && di == 144) word_of = RbHdr;
    else if (has_chain && di == 145) word_of = APU_VIRGL_RZ_HANDLE;
    else if (has_chain && di == 146) word_of = VsbHdr;
    else if (has_chain && di == 147) word_of = APU_VIRGL_VS_HANDLE;
    else if (has_chain && di == 148) word_of = 32'(APU_VIRGL_SHADER_VERTEX);
    else if (has_chain && di == 149) word_of = FsbHdr;
    else if (has_chain && di == 150) word_of = APU_VIRGL_FS_HANDLE;
    else if (has_chain && di == 151) word_of = 32'(APU_VIRGL_SHADER_FRAGMENT);
    else if (img == 1 && di == 152)
      word_of = {16'd2, APU_VIRGL_OBJ_VERTEX_ELEMENTS, APU_VIRGL_BIND_OBJECT};
    else if ((img == 2 || img == 3) && di == 152) word_of = VebHdr;
    else if (img == 2 && di == 153) word_of = APU_VIRGL_BL_HANDLE;
    else if (img == 3 && di == 153) word_of = APU_VIRGL_VE_HANDLE;
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
    use_bb = 1'b0;
    use_db = 1'b0;
    use_rb = 1'b0;
    use_vsb = 1'b0;
    use_fsb = 1'b0;
    use_veb = 1'b0;
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
    @(negedge clk);
    while (!zreq_rdy) @(negedge clk);
    cases++;
    quiet_peek();
    use_rz = 1'b1;
    zreq_v = 1;
    @(posedge clk); @(negedge clk); zreq_v = 0;
    while (!zcpl_v) @(negedge clk);
    check($sformatf("%s status", name), zcpl.status == st);
    @(negedge clk);
    zcpl_r = 1;
    @(posedge clk); @(negedge clk); zcpl_r = 0;
    while (zcpl_v) @(negedge clk);
  endtask

  task automatic bb_step(input apu_vgpu_bb_status_e st, input string name);
    @(negedge clk);
    while (!mreq_rdy) @(negedge clk);
    cases++;
    quiet_peek();
    use_bb = 1'b1;
    mreq_v = 1;
    @(posedge clk); @(negedge clk); mreq_v = 0;
    while (!mcpl_v) @(negedge clk);
    check($sformatf("%s status", name), mcpl.status == st);
    @(negedge clk);
    mcpl_r = 1;
    @(posedge clk); @(negedge clk); mcpl_r = 0;
    while (mcpl_v) @(negedge clk);
  endtask

  task automatic db_step(input apu_vgpu_db_status_e st, input string name);
    @(negedge clk);
    while (!nreq_rdy) @(negedge clk);
    cases++;
    quiet_peek();
    use_db = 1'b1;
    nreq_v = 1;
    @(posedge clk); @(negedge clk); nreq_v = 0;
    while (!ncpl_v) @(negedge clk);
    check($sformatf("%s status", name), ncpl.status == st);
    @(negedge clk);
    ncpl_r = 1;
    @(posedge clk); @(negedge clk); ncpl_r = 0;
    while (ncpl_v) @(negedge clk);
  endtask

  task automatic rb_step(input apu_vgpu_rb_status_e st, input string name);
    apu_vgpu_rb_cpl_t seen;
    apu_vgpu_rb_t was;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    was = rbound;
    quiet_peek();
    use_rb = 1'b1;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    while (!cpl_v) @(negedge clk);
    seen = cpl;
    check($sformatf("%s status", name), cpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), cpl_v && !req_rdy && cpl == seen);
    if (st != APU_VGPU_RB_OK)
      check($sformatf("%s unchanged", name), rbound == was);
    cpl_r = 1;
    @(posedge clk); @(negedge clk); cpl_r = 0;
    while (cpl_v) @(negedge clk);
    if (st != APU_VGPU_RB_OK)
      check($sformatf("%s kept", name), rbound == was);
  endtask

  task automatic vsb_step(input apu_vgpu_vsb_status_e st, input string name);
    apu_vgpu_vsb_cpl_t seen;
    apu_vgpu_vsb_t was;
    @(negedge clk);
    while (!wreq_rdy) @(negedge clk);
    cases++;
    was = vsbound;
    quiet_peek();
    use_vsb = 1'b1;
    wreq_v = 1;
    @(posedge clk); @(negedge clk); wreq_v = 0;
    while (!wcpl_v) @(negedge clk);
    seen = wcpl;
    check($sformatf("%s status", name), wcpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), wcpl_v && !wreq_rdy && wcpl == seen);
    if (st != APU_VGPU_VSB_OK)
      check($sformatf("%s unchanged", name), vsbound == was);
    wcpl_r = 1;
    @(posedge clk); @(negedge clk); wcpl_r = 0;
    while (wcpl_v) @(negedge clk);
    if (st != APU_VGPU_VSB_OK)
      check($sformatf("%s kept", name), vsbound == was);
  endtask

  task automatic fsb_step(input apu_vgpu_fsb_status_e st, input string name);
    apu_vgpu_fsb_cpl_t seen;
    apu_vgpu_fsb_t was;
    @(negedge clk);
    while (!kreq_rdy) @(negedge clk);
    cases++;
    was = fsbound;
    quiet_peek();
    use_fsb = 1'b1;
    kreq_v = 1;
    @(posedge clk); @(negedge clk); kreq_v = 0;
    while (!kcpl_v) @(negedge clk);
    seen = kcpl;
    check($sformatf("%s status", name), kcpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), kcpl_v && !kreq_rdy && kcpl == seen);
    if (st != APU_VGPU_FSB_OK)
      check($sformatf("%s unchanged", name), fsbound == was);
    kcpl_r = 1;
    @(posedge clk); @(negedge clk); kcpl_r = 0;
    while (kcpl_v) @(negedge clk);
    if (st != APU_VGPU_FSB_OK)
      check($sformatf("%s kept", name), fsbound == was);
  endtask

  task automatic veb_step(input apu_vgpu_veb_status_e st, input string name);
    apu_vgpu_veb_cpl_t seen;
    apu_vgpu_veb_t was;
    @(negedge clk);
    while (!jreq_rdy) @(negedge clk);
    cases++;
    was = vebound;
    quiet_peek();
    use_veb = 1'b1;
    jreq_v = 1;
    @(posedge clk); @(negedge clk); jreq_v = 0;
    while (!jcpl_v) @(negedge clk);
    seen = jcpl;
    check($sformatf("%s status", name), jcpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), jcpl_v && !jreq_rdy && jcpl == seen);
    if (st != APU_VGPU_VEB_OK)
      check($sformatf("%s unchanged", name), vebound == was);
    jcpl_r = 1;
    @(posedge clk); @(negedge clk); jcpl_r = 0;
    while (jcpl_v) @(negedge clk);
    if (st != APU_VGPU_VEB_OK)
      check($sformatf("%s kept", name), vebound == was);
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
    zreq_v = 0;
    zcpl_r = 0;
    mreq_v = 0;
    mcpl_r = 0;
    nreq_v = 0;
    ncpl_r = 0;
    req_v = 0;
    cpl_r = 0;
    wreq_v = 0;
    wcpl_r = 0;
    kreq_v = 0;
    kcpl_r = 0;
    jreq_v = 0;
    jcpl_r = 0;
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
    check("off stays quiet", off_rdy == 0 && off_v == 0 && jreq_rdy == 1 && vebound == '0);
    check("profiles keep veb off",
          !ApuOff.VebEn && !ApuP1Transport.VebEn && !ApuHarness.VebEn &&
          !ApuSchedBoth.VebEn && !ApuBadVirglGrant.VebEn);
    cfg = ApuP1Transport;
    cfg.VebEn = 1'b1;
    check("veb does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.VebEn = 1'b1;
    check("veb does not legalize virgl", !apu_cfg_legal(cfg));

    veb_step(APU_VGPU_VEB_EMPTY, "empty");

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
    rz_step(APU_VGPU_RZ_EMPTY, "surf rz");
    bb_step(APU_VGPU_BB_EMPTY, "surf bb");
    db_step(APU_VGPU_DB_EMPTY, "surf db");
    rb_step(APU_VGPU_RB_EMPTY, "surf rb");
    vsb_step(APU_VGPU_VSB_EMPTY, "surf vsb");
    fsb_step(APU_VGPU_FSB_EMPTY, "surf fsb");
    veb_step(APU_VGPU_VEB_EMPTY, "before bind");
    check("before clear", vebound == '0);

    pulse_reset();
    img = 5;
    load_buf(32'd608, "room load");
    dec_step("room dec");
    sh_step(APU_VGPU_SH_OK, "room sh");
    fs_step(APU_VGPU_SH_OK, "room fs");
    ve_step(APU_VGPU_VE_OK, "room ve");
    sv_step(APU_VGPU_SV_OK, "room sv");
    ss_step(APU_VGPU_SS_OK, "room ss");
    bl_step(APU_VGPU_BL_OK, "room bl");
    ds_step(APU_VGPU_DS_OK, "room ds");
    rz_step(APU_VGPU_RZ_OK, "room rz");
    bb_step(APU_VGPU_BB_OK, "room bb");
    db_step(APU_VGPU_DB_OK, "room db");
    rb_step(APU_VGPU_RB_OK, "room rb");
    vsb_step(APU_VGPU_VSB_OK, "room vsb");
    fsb_step(APU_VGPU_FSB_OK, "room fsb");
    check("fs bind parked", fsbound.valid && fsbound.next == 32'd608 &&
          fsbound.handle == APU_VIRGL_FS_HANDLE &&
          fsbound.stage == APU_VIRGL_SHADER_FRAGMENT);
    veb_step(APU_VGPU_VEB_FAULT, "no room");
    check("no room clear", vebound == '0);
    check("fs bind stays", fsbound.valid && fsbound.next == 32'd608 &&
          fsbound.handle == APU_VIRGL_FS_HANDLE);

    pulse_reset();
    img = 1;
    load_buf(32'd620, "count load");
    dec_step("count dec");
    sh_step(APU_VGPU_SH_OK, "count sh");
    fs_step(APU_VGPU_SH_OK, "count fs");
    ve_step(APU_VGPU_VE_OK, "count ve");
    sv_step(APU_VGPU_SV_OK, "count sv");
    ss_step(APU_VGPU_SS_OK, "count ss");
    bl_step(APU_VGPU_BL_OK, "count bl");
    ds_step(APU_VGPU_DS_OK, "count ds");
    rz_step(APU_VGPU_RZ_OK, "count rz");
    bb_step(APU_VGPU_BB_OK, "count bb");
    db_step(APU_VGPU_DB_OK, "count db");
    rb_step(APU_VGPU_RB_OK, "count rb");
    vsb_step(APU_VGPU_VSB_OK, "count vsb");
    fsb_step(APU_VGPU_FSB_OK, "count fsb");
    veb_step(APU_VGPU_VEB_FAULT, "bad count");
    check("bad count clear", vebound == '0);

    pulse_reset();
    img = 2;
    load_buf(32'd616, "handle load");
    dec_step("handle dec");
    sh_step(APU_VGPU_SH_OK, "handle sh");
    fs_step(APU_VGPU_SH_OK, "handle fs");
    ve_step(APU_VGPU_VE_OK, "handle ve");
    sv_step(APU_VGPU_SV_OK, "handle sv");
    ss_step(APU_VGPU_SS_OK, "handle ss");
    bl_step(APU_VGPU_BL_OK, "handle bl");
    ds_step(APU_VGPU_DS_OK, "handle ds");
    rz_step(APU_VGPU_RZ_OK, "handle rz");
    bb_step(APU_VGPU_BB_OK, "handle bb");
    db_step(APU_VGPU_DB_OK, "handle db");
    rb_step(APU_VGPU_RB_OK, "handle rb");
    vsb_step(APU_VGPU_VSB_OK, "handle vsb");
    fsb_step(APU_VGPU_FSB_OK, "handle fsb");
    veb_step(APU_VGPU_VEB_FAULT, "bad handle");
    check("bad handle clear", vebound == '0);

    pulse_reset();
    img = 3;
    load_buf(32'd616, "bind load");
    dec_step("bind dec");
    sh_step(APU_VGPU_SH_OK, "bind sh");
    fs_step(APU_VGPU_SH_OK, "bind fs");
    ve_step(APU_VGPU_VE_OK, "bind ve");
    sv_step(APU_VGPU_SV_OK, "bind sv");
    ss_step(APU_VGPU_SS_OK, "bind ss");
    bl_step(APU_VGPU_BL_OK, "bind bl");
    ds_step(APU_VGPU_DS_OK, "bind ds");
    rz_step(APU_VGPU_RZ_OK, "bind rz");
    bb_step(APU_VGPU_BB_OK, "bind bb");
    db_step(APU_VGPU_DB_OK, "bind db");
    rb_step(APU_VGPU_RB_OK, "bind rb");
    vsb_step(APU_VGPU_VSB_OK, "bind vsb");
    fsb_step(APU_VGPU_FSB_OK, "bind fsb");
    veb_step(APU_VGPU_VEB_OK, "bind");
    check("bind id", vebound.valid && vebound.handle == APU_VIRGL_VE_HANDLE &&
          vebound.next == 32'd616);
    check("fs bind stays", fsbound.valid && fsbound.handle == APU_VIRGL_FS_HANDLE &&
          fsbound.stage == APU_VIRGL_SHADER_FRAGMENT && fsbound.next == 32'd608);
    veb_step(APU_VGPU_VEB_FAULT, "second");
    check("second keeps", vebound.valid && vebound.handle == APU_VIRGL_VE_HANDLE &&
          vebound.next == 32'd616);

    if (errors != 0) $fatal(1, "APU vgpu veb errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_veb cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
