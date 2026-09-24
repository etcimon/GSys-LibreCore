// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_tail;
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
  logic [APU_VGPU_BUF_ADDRW-1:0] db_peek, rb_peek, vsb_peek, fsb_peek, veb_peek, ssb_peek, svb_peek, iw_peek, vb_peek, sci_peek;
  logic [APU_VGPU_BUF_ADDRW-1:0] vp_peek, fbo_peek, clr_peek, drw_peek, off_peek;
  logic [31:0] peek_word;
  logic use_sh = 0, use_fs = 0, use_ve = 0, use_sv = 0, use_ss = 0;
  logic use_bl = 0, use_ds = 0, use_rz = 0, use_bb = 0, use_db = 0, use_rb = 0;
  logic use_vsb = 0, use_fsb = 0, use_veb = 0, use_ssb = 0, use_svb = 0, use_iw = 0, use_vb = 0, use_sci = 0;
  logic use_vp = 0, use_fbo = 0, use_clr = 0, use_drw = 0;

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
  apu_vgpu_veb_cpl_t jcpl;
  apu_vgpu_veb_t vebound;
  logic qreq_v = 0, qreq_rdy, qcpl_v, qcpl_r = 0;
  apu_vgpu_ssb_cpl_t qcpl;
  apu_vgpu_ssb_t ssbound;
  logic ireq_v = 0, ireq_rdy, icpl_v, icpl_r = 0;
  apu_vgpu_svb_cpl_t icpl;
  apu_vgpu_svb_t svbound;
  logic rreq_v = 0, rreq_rdy, rcpl_v, rcpl_r = 0;
  apu_vgpu_iw_cpl_t rcpl;
  apu_vgpu_iw_t iwrite;
  logic xreq_v = 0, xreq_rdy, xcpl_v, xcpl_r = 0;
  apu_vgpu_vb_cpl_t xcpl;
  apu_vgpu_vb_t vset;
  logic yreq_v = 0, yreq_rdy, ycpl_v, ycpl_r = 0;
  apu_vgpu_sci_cpl_t ycpl;
  apu_vgpu_sci_t sbox;
  logic preq_v = 0, preq_rdy, pcpl_v, pcpl_r = 0;
  apu_vgpu_vp_cpl_t pcpl;
  apu_vgpu_vp_t vpbound;
  logic greq_v = 0, greq_rdy, gcpl_v, gcpl_r = 0;
  apu_vgpu_fbo_cpl_t gcpl;
  apu_vgpu_fbo_t fbound;
  logic hreq_v = 0, hreq_rdy, hcpl_v, hcpl_r = 0;
  apu_vgpu_clr_cpl_t hcpl;
  apu_vgpu_clr_t cbound;
  logic oreq_v = 0, oreq_rdy, ocpl_v, ocpl_r = 0;
  logic off_rdy, off_v;
  apu_vgpu_drw_cpl_t ocpl, off_cpl;
  apu_vgpu_drw_t dbound, off_drw;
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
  localparam logic [31:0] SsbHdr = {16'd3, 8'd0, APU_VIRGL_BIND_SAMPLER_STATES};
  localparam logic [31:0] SvbHdr = {16'd3, 8'd0, APU_VIRGL_SET_SAMPLER_VIEWS};
  localparam logic [31:0] IwHdr = {16'd35, 8'd0, APU_VIRGL_INLINE_WRITE};
  localparam logic [31:0] VbHdr = {16'd3, 8'd0, APU_VIRGL_SET_VERTEX_BUFFERS};
  localparam logic [31:0] SciHdr = {16'd3, 8'd0, APU_VIRGL_SET_SCISSOR};

  assign buf_sub = use_force ? forced : apu_vgpu_sub_t'('0);
  assign peek_addr = use_drw ? drw_peek : use_clr ? clr_peek : use_fbo ? fbo_peek :
                     use_vp ? vp_peek : use_sci ? sci_peek : use_vb ? vb_peek :
                     use_iw ? iw_peek :
                     use_svb ? svb_peek :
                     use_ssb ? ssb_peek :
                     use_veb ? veb_peek :
                     use_fsb ? fsb_peek :
                     use_vsb ? vsb_peek :
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
  g6lc_apu_vgpu_ssb #(.Enable(1'b1)) i_ssb (
    .clk_i(clk), .rst_ni, .buf_i(live), .veb_i(vebound),
    .req_valid_i(qreq_v), .req_ready_o(qreq_rdy),
    .cpl_valid_o(qcpl_v), .cpl_ready_i(qcpl_r), .cpl_o(qcpl), .ssb_o(ssbound),
    .peek_addr_o(ssb_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_svb #(.Enable(1'b1)) i_svb (
    .clk_i(clk), .rst_ni, .buf_i(live), .ssb_i(ssbound),
    .req_valid_i(ireq_v), .req_ready_o(ireq_rdy),
    .cpl_valid_o(icpl_v), .cpl_ready_i(icpl_r), .cpl_o(icpl), .svb_o(svbound),
    .peek_addr_o(svb_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_iw #(.Enable(1'b1)) i_iw (
    .clk_i(clk), .rst_ni, .buf_i(live), .svb_i(svbound),
    .req_valid_i(rreq_v), .req_ready_o(rreq_rdy),
    .cpl_valid_o(rcpl_v), .cpl_ready_i(rcpl_r), .cpl_o(rcpl), .iw_o(iwrite),
    .peek_addr_o(iw_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_vb #(.Enable(1'b1)) i_vb (
    .clk_i(clk), .rst_ni, .buf_i(live), .iw_i(iwrite),
    .req_valid_i(xreq_v), .req_ready_o(xreq_rdy),
    .cpl_valid_o(xcpl_v), .cpl_ready_i(xcpl_r), .cpl_o(xcpl), .vb_o(vset),
    .peek_addr_o(vb_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_sci #(.Enable(1'b1)) i_sci (
    .clk_i(clk), .rst_ni, .buf_i(live), .vb_i(vset),
    .req_valid_i(yreq_v), .req_ready_o(yreq_rdy),
    .cpl_valid_o(ycpl_v), .cpl_ready_i(ycpl_r), .cpl_o(ycpl), .sci_o(sbox),
    .peek_addr_o(sci_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_vp #(.Enable(1'b1)) i_vp (
    .clk_i(clk), .rst_ni, .buf_i(live), .sci_i(sbox),
    .req_valid_i(preq_v), .req_ready_o(preq_rdy),
    .cpl_valid_o(pcpl_v), .cpl_ready_i(pcpl_r), .cpl_o(pcpl), .vp_o(vpbound),
    .peek_addr_o(vp_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_fbo #(.Enable(1'b1)) i_fbo (
    .clk_i(clk), .rst_ni, .buf_i(live), .vp_i(vpbound),
    .req_valid_i(greq_v), .req_ready_o(greq_rdy),
    .cpl_valid_o(gcpl_v), .cpl_ready_i(gcpl_r), .cpl_o(gcpl), .fbo_o(fbound),
    .peek_addr_o(fbo_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_clr #(.Enable(1'b1)) i_clr (
    .clk_i(clk), .rst_ni, .buf_i(live), .fbo_i(fbound),
    .req_valid_i(hreq_v), .req_ready_o(hreq_rdy),
    .cpl_valid_o(hcpl_v), .cpl_ready_i(hcpl_r), .cpl_o(hcpl), .clr_o(cbound),
    .peek_addr_o(clr_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_drw #(.Enable(1'b1)) i_drw (
    .clk_i(clk), .rst_ni, .buf_i(live), .clr_i(cbound),
    .req_valid_i(oreq_v), .req_ready_o(oreq_rdy),
    .cpl_valid_o(ocpl_v), .cpl_ready_i(ocpl_r), .cpl_o(ocpl), .drw_o(dbound),
    .peek_addr_o(drw_peek), .peek_word_i(peek_word)
  );
  g6lc_apu_vgpu_drw_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .buf_i(live), .clr_i(cbound),
    .req_valid_i(oreq_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(ocpl_r), .cpl_o(off_cpl), .drw_o(off_drw),
    .peek_addr_o(off_peek), .peek_word_i(peek_word)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #1000000; $fatal(1, "vgpu tail timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 0 || off_v !== 0 || off_cpl !== '0 || off_drw !== '0 || off_peek !== 0)
      $fatal(1, "disabled vgpu tail active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  function automatic logic [31:0] quad_bits(input logic [31:0] k);
    logic neg, one;
    neg = 1'b0;
    one = 1'b0;
    case (k)
      32'd0, 32'd1, 32'd7, 32'd12: neg = 1'b1;
      32'd3, 32'd6, 32'd9, 32'd10, 32'd13, 32'd15, 32'd17, 32'd18, 32'd19,
      32'd21, 32'd22, 32'd23: one = 1'b1;
      default: ;
    endcase
    if (neg) quad_bits = APU_VIRGL_F32_NEG_ONE;
    else if (one) quad_bits = 32'h3f800000;
    else quad_bits = 32'h0;
  endfunction

  function automatic logic [31:0] word_of(input logic [31:0] di);
    logic has_chain;
    word_of = '0;
    has_chain = img == 1 || img == 2 || img == 3 || img == 5 || img == 6 || img == 7 ||
                img == 8 || img == 9 || img == 10 || img == 11 || img == 12 ||
                img == 13 || img == 14;
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
    else if (has_chain && di == 152) word_of = VebHdr;
    else if (has_chain && di == 153) word_of = APU_VIRGL_VE_HANDLE;
    else if (has_chain && di == 154) word_of = SsbHdr;
    else if (has_chain && di == 155) word_of = 32'(APU_VIRGL_SHADER_FRAGMENT);
    else if (has_chain && di == 156) word_of = 32'h0;
    else if (has_chain && di == 157) word_of = APU_VIRGL_SS_HANDLE;
    else if (has_chain && di == 158) word_of = SvbHdr;
    else if (has_chain && di == 159) word_of = 32'(APU_VIRGL_SHADER_FRAGMENT);
    else if (has_chain && di == 160) word_of = 32'h0;
    else if (has_chain && di == 161) word_of = APU_VIRGL_SV_HANDLE;
    else if (has_chain && di == 162) word_of = IwHdr;
    else if (has_chain && di == 163) word_of = APU_VIRGL_RES_VBO;
    else if (has_chain && di == 171) word_of = APU_VIRGL_VBO_BYTES;
    else if (has_chain && (di == 172 || di == 173)) word_of = 32'd1;
    else if (has_chain && di == 174) word_of = APU_VIRGL_F32_NEG_ONE;
    else if (img == 3 && di >= 32'd175 && di < 32'd198) word_of = quad_bits(di - 32'd174);
    else if (has_chain && di == 198) word_of = VbHdr;
    else if (has_chain && di == 199) word_of = APU_VIRGL_VERT_STRIDE;
    else if (has_chain && di == 200) word_of = 32'h0;
    else if (has_chain && di == 201) word_of = APU_VIRGL_RES_VBO;
    else if ((img == 1 || img == 2 || img == 3 || img == 5 || img == 6 || img == 7 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 202) word_of = SciHdr;
    else if ((img == 1 || img == 2 || img == 3 || img == 5 || img == 6 || img == 7 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 203) word_of = 32'h0;
    else if ((img == 1 || img == 2 || img == 3 || img == 5 || img == 6 || img == 7 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 204) word_of = 32'h0;
    else if ((img == 1 || img == 2 || img == 3 || img == 5 || img == 6 || img == 7 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 205) word_of = APU_VIRGL_SCISSOR_BOX;
    else if (img == 1 && di == 206) word_of = {16'd1, 8'd0, APU_VIRGL_SET_VIEWPORT};
    else if ((img == 2 || img == 3 || img == 6 || img == 7 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 206) word_of = {16'd7, 8'd0, APU_VIRGL_SET_VIEWPORT};
    else if (img == 2 && di == 207) word_of = 32'h0;
    else if (img == 2 && di == 208) word_of = 32'h0;
    else if (img == 2 && di == 209) word_of = APU_VIRGL_F32_HALF_H;
    else if (img == 2 && di == 210) word_of = APU_VIRGL_F32_ONE;
    else if (img == 2 && di == 211) word_of = APU_VIRGL_F32_HALF_W;
    else if (img == 2 && di == 212) word_of = APU_VIRGL_F32_HALF_H;
    else if (img == 2 && di == 213) word_of = 32'h0;
    else if ((img == 3 || img == 6 || img == 7 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 207) word_of = 32'h0;
    else if ((img == 3 || img == 6 || img == 7 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 208) word_of = APU_VIRGL_F32_HALF_W;
    else if ((img == 3 || img == 6 || img == 7 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 209) word_of = APU_VIRGL_F32_HALF_H;
    else if ((img == 3 || img == 6 || img == 7 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 210) word_of = APU_VIRGL_F32_ONE;
    else if ((img == 3 || img == 6 || img == 7 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 211) word_of = APU_VIRGL_F32_HALF_W;
    else if ((img == 3 || img == 6 || img == 7 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 212) word_of = APU_VIRGL_F32_HALF_H;
    else if ((img == 3 || img == 6 || img == 7 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 213) word_of = 32'h0;
    else if (img == 7 && di == 214) word_of = {16'd1, 8'd0, APU_VIRGL_SET_FRAMEBUFFER};
    else if ((img == 3 || img == 8 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 214) word_of = {16'd3, 8'd0, APU_VIRGL_SET_FRAMEBUFFER};
    else if (img == 8 && di == 215) word_of = 32'd1;
    else if (img == 8 && di == 216) word_of = 32'h0;
    else if (img == 8 && di == 217) word_of = 32'd2;
    else if ((img == 3 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 215) word_of = 32'd1;
    else if ((img == 3 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 216) word_of = 32'h0;
    else if ((img == 3 || img == 9 || img == 10 || img == 11 || img == 12 || img == 13 || img == 14) && di == 217) word_of = APU_VIRGL_SURFACE_HANDLE;
    else if (img == 10 && di == 218) word_of = {16'd1, 8'd0, APU_VIRGL_CLEAR};
    else if ((img == 3 || img == 11 || img == 12 || img == 13 || img == 14) && di == 218) word_of = {16'd8, 8'd0, APU_VIRGL_CLEAR};
    else if (img == 11 && di == 219) word_of = APU_VIRGL_CLEAR_COLOR;
    else if (img == 11 && di == 220) word_of = 32'h0;
    else if (img == 11 && di == 221) word_of = APU_VIRGL_F32_P05;
    else if (img == 11 && di == 222) word_of = APU_VIRGL_F32_P10;
    else if (img == 11 && di == 223) word_of = APU_VIRGL_F32_ONE;
    else if (img == 11 && di == 224) word_of = 32'h0;
    else if (img == 11 && di == 225) word_of = APU_VIRGL_DEPTH_HI;
    else if (img == 11 && di == 226) word_of = 32'h0;
    else if ((img == 3 || img == 12 || img == 13 || img == 14) && di == 219) word_of = APU_VIRGL_CLEAR_COLOR;
    else if ((img == 3 || img == 12 || img == 13 || img == 14) && di == 220) word_of = APU_VIRGL_F32_P05;
    else if ((img == 3 || img == 12 || img == 13 || img == 14) && di == 221) word_of = APU_VIRGL_F32_P05;
    else if ((img == 3 || img == 12 || img == 13 || img == 14) && di == 222) word_of = APU_VIRGL_F32_P10;
    else if ((img == 3 || img == 12 || img == 13 || img == 14) && di == 223) word_of = APU_VIRGL_F32_ONE;
    else if ((img == 3 || img == 12 || img == 13 || img == 14) && di == 224) word_of = 32'h0;
    else if ((img == 3 || img == 12 || img == 13 || img == 14) && di == 225) word_of = APU_VIRGL_DEPTH_HI;
    else if ((img == 3 || img == 12 || img == 13 || img == 14) && di == 226) word_of = 32'h0;
    else if (img == 13 && di == 227) word_of = {16'd1, 8'd0, APU_VIRGL_DRAW_VBO};
    else if ((img == 3 || img == 14) && di == 227) word_of = {16'd12, 8'd0, APU_VIRGL_DRAW_VBO};
    else if (img == 14 && di == 228) word_of = 32'h0;
    else if (img == 14 && di == 229) word_of = APU_VIRGL_VERT_COUNT;
    else if (img == 14 && di == 230) word_of = 32'h0;
    else if (img == 14 && di == 231) word_of = 32'h0;
    else if (img == 14 && di == 232) word_of = 32'd1;
    else if (img == 14 && di == 233) word_of = 32'h0;
    else if (img == 14 && di == 234) word_of = 32'h0;
    else if (img == 14 && di == 235) word_of = 32'h0;
    else if (img == 14 && di == 236) word_of = 32'h0;
    else if (img == 14 && di == 237) word_of = 32'h0;
    else if (img == 14 && di == 238) word_of = 32'd3;
    else if (img == 14 && di == 239) word_of = 32'h0;
    else if (img == 3 && di == 228) word_of = 32'h0;
    else if (img == 3 && di == 229) word_of = APU_VIRGL_VERT_COUNT;
    else if (img == 3 && di == 230) word_of = APU_VIRGL_PRIM_STRIP;
    else if (img == 3 && di == 231) word_of = 32'h0;
    else if (img == 3 && di == 232) word_of = 32'd1;
    else if (img == 3 && di == 233) word_of = 32'h0;
    else if (img == 3 && di == 234) word_of = 32'h0;
    else if (img == 3 && di == 235) word_of = 32'h0;
    else if (img == 3 && di == 236) word_of = 32'h0;
    else if (img == 3 && di == 237) word_of = 32'h0;
    else if (img == 3 && di == 238) word_of = 32'd3;
    else if (img == 3 && di == 239) word_of = 32'h0;
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
    use_ssb = 1'b0;
    use_svb = 1'b0;
    use_iw = 1'b0;
    use_vb = 1'b0;
    use_sci = 1'b0;
    use_vp = 1'b0;
    use_fbo = 1'b0;
    use_clr = 1'b0;
    use_drw = 1'b0;
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

  task automatic ssb_step(input apu_vgpu_ssb_status_e st, input string name);
    apu_vgpu_ssb_cpl_t seen;
    apu_vgpu_ssb_t was;
    @(negedge clk);
    while (!qreq_rdy) @(negedge clk);
    cases++;
    was = ssbound;
    quiet_peek();
    use_ssb = 1'b1;
    qreq_v = 1;
    @(posedge clk); @(negedge clk); qreq_v = 0;
    while (!qcpl_v) @(negedge clk);
    seen = qcpl;
    check($sformatf("%s status", name), qcpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), qcpl_v && !qreq_rdy && qcpl == seen);
    if (st != APU_VGPU_SSB_OK)
      check($sformatf("%s unchanged", name), ssbound == was);
    qcpl_r = 1;
    @(posedge clk); @(negedge clk); qcpl_r = 0;
    while (qcpl_v) @(negedge clk);
    if (st != APU_VGPU_SSB_OK)
      check($sformatf("%s kept", name), ssbound == was);
  endtask

  task automatic svb_step(input apu_vgpu_svb_status_e st, input string name);
    apu_vgpu_svb_cpl_t seen;
    apu_vgpu_svb_t was;
    @(negedge clk);
    while (!ireq_rdy) @(negedge clk);
    cases++;
    was = svbound;
    quiet_peek();
    use_svb = 1'b1;
    ireq_v = 1;
    @(posedge clk); @(negedge clk); ireq_v = 0;
    while (!icpl_v) @(negedge clk);
    seen = icpl;
    check($sformatf("%s status", name), icpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), icpl_v && !ireq_rdy && icpl == seen);
    if (st != APU_VGPU_SVB_OK)
      check($sformatf("%s unchanged", name), svbound == was);
    icpl_r = 1;
    @(posedge clk); @(negedge clk); icpl_r = 0;
    while (icpl_v) @(negedge clk);
    if (st != APU_VGPU_SVB_OK)
      check($sformatf("%s kept", name), svbound == was);
  endtask

  task automatic iw_step(input apu_vgpu_iw_status_e st, input string name);
    apu_vgpu_iw_cpl_t seen;
    apu_vgpu_iw_t was;
    @(negedge clk);
    while (!rreq_rdy) @(negedge clk);
    cases++;
    was = iwrite;
    quiet_peek();
    use_iw = 1'b1;
    rreq_v = 1;
    @(posedge clk); @(negedge clk); rreq_v = 0;
    while (!rcpl_v) @(negedge clk);
    seen = rcpl;
    check($sformatf("%s status", name), rcpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), rcpl_v && !rreq_rdy && rcpl == seen);
    if (st != APU_VGPU_IW_OK)
      check($sformatf("%s unchanged", name), iwrite == was);
    rcpl_r = 1;
    @(posedge clk); @(negedge clk); rcpl_r = 0;
    while (rcpl_v) @(negedge clk);
    if (st != APU_VGPU_IW_OK)
      check($sformatf("%s kept", name), iwrite == was);
  endtask

  task automatic vb_step(input apu_vgpu_vb_status_e st, input string name);
    apu_vgpu_vb_cpl_t seen;
    apu_vgpu_vb_t was;
    @(negedge clk);
    while (!xreq_rdy) @(negedge clk);
    cases++;
    was = vset;
    quiet_peek();
    use_vb = 1'b1;
    xreq_v = 1;
    @(posedge clk); @(negedge clk); xreq_v = 0;
    while (!xcpl_v) @(negedge clk);
    seen = xcpl;
    check($sformatf("%s status", name), xcpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), xcpl_v && !xreq_rdy && xcpl == seen);
    if (st != APU_VGPU_VB_OK)
      check($sformatf("%s unchanged", name), vset == was);
    xcpl_r = 1;
    @(posedge clk); @(negedge clk); xcpl_r = 0;
    while (xcpl_v) @(negedge clk);
    if (st != APU_VGPU_VB_OK)
      check($sformatf("%s kept", name), vset == was);
  endtask

  task automatic sci_step(input apu_vgpu_sci_status_e st, input string name);
    apu_vgpu_sci_cpl_t seen;
    apu_vgpu_sci_t was;
    @(negedge clk);
    while (!yreq_rdy) @(negedge clk);
    cases++;
    was = sbox;
    quiet_peek();
    use_sci = 1'b1;
    yreq_v = 1;
    @(posedge clk); @(negedge clk); yreq_v = 0;
    while (!ycpl_v) @(negedge clk);
    seen = ycpl;
    check($sformatf("%s status", name), ycpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), ycpl_v && !yreq_rdy && ycpl == seen);
    if (st != APU_VGPU_SCI_OK)
      check($sformatf("%s unchanged", name), sbox == was);
    ycpl_r = 1;
    @(posedge clk); @(negedge clk); ycpl_r = 0;
    while (ycpl_v) @(negedge clk);
    if (st != APU_VGPU_SCI_OK)
      check($sformatf("%s kept", name), sbox == was);
  endtask

  task automatic vp_step(input apu_vgpu_vp_status_e st, input string name);
    apu_vgpu_vp_cpl_t seen;
    apu_vgpu_vp_t was;
    @(negedge clk);
    while (!preq_rdy) @(negedge clk);
    cases++;
    was = vpbound;
    quiet_peek();
    use_vp = 1'b1;
    preq_v = 1;
    @(posedge clk); @(negedge clk); preq_v = 0;
    while (!pcpl_v) @(negedge clk);
    seen = pcpl;
    check($sformatf("%s status", name), pcpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), pcpl_v && !preq_rdy && pcpl == seen);
    if (st != APU_VGPU_VP_OK)
      check($sformatf("%s unchanged", name), vpbound == was);
    pcpl_r = 1;
    @(posedge clk); @(negedge clk); pcpl_r = 0;
    while (pcpl_v) @(negedge clk);
    if (st != APU_VGPU_VP_OK)
      check($sformatf("%s kept", name), vpbound == was);
  endtask

  task automatic fbo_step(input apu_vgpu_fbo_status_e st, input string name);
    apu_vgpu_fbo_cpl_t seen;
    apu_vgpu_fbo_t was;
    @(negedge clk);
    while (!greq_rdy) @(negedge clk);
    cases++;
    was = fbound;
    quiet_peek();
    use_fbo = 1'b1;
    greq_v = 1;
    @(posedge clk); @(negedge clk); greq_v = 0;
    while (!gcpl_v) @(negedge clk);
    seen = gcpl;
    check($sformatf("%s status", name), gcpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), gcpl_v && !greq_rdy && gcpl == seen);
    if (st != APU_VGPU_FBO_OK)
      check($sformatf("%s unchanged", name), fbound == was);
    gcpl_r = 1;
    @(posedge clk); @(negedge clk); gcpl_r = 0;
    while (gcpl_v) @(negedge clk);
    if (st != APU_VGPU_FBO_OK)
      check($sformatf("%s kept", name), fbound == was);
  endtask

  task automatic clr_step(input apu_vgpu_clr_status_e st, input string name);
    apu_vgpu_clr_cpl_t seen;
    apu_vgpu_clr_t was;
    @(negedge clk);
    while (!hreq_rdy) @(negedge clk);
    cases++;
    was = cbound;
    quiet_peek();
    use_clr = 1'b1;
    hreq_v = 1;
    @(posedge clk); @(negedge clk); hreq_v = 0;
    while (!hcpl_v) @(negedge clk);
    seen = hcpl;
    check($sformatf("%s status", name), hcpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), hcpl_v && !hreq_rdy && hcpl == seen);
    if (st != APU_VGPU_CLR_OK)
      check($sformatf("%s unchanged", name), cbound == was);
    hcpl_r = 1;
    @(posedge clk); @(negedge clk); hcpl_r = 0;
    while (hcpl_v) @(negedge clk);
    if (st != APU_VGPU_CLR_OK)
      check($sformatf("%s kept", name), cbound == was);
  endtask

  task automatic drw_step(input apu_vgpu_drw_status_e st, input string name);
    apu_vgpu_drw_cpl_t seen;
    apu_vgpu_drw_t was;
    @(negedge clk);
    while (!oreq_rdy) @(negedge clk);
    cases++;
    was = dbound;
    quiet_peek();
    use_drw = 1'b1;
    oreq_v = 1;
    @(posedge clk); @(negedge clk); oreq_v = 0;
    while (!ocpl_v) @(negedge clk);
    seen = ocpl;
    check($sformatf("%s status", name), ocpl.status == st);
    @(negedge clk);
    check($sformatf("%s held", name), ocpl_v && !oreq_rdy && ocpl == seen);
    if (st != APU_VGPU_DRW_OK)
      check($sformatf("%s unchanged", name), dbound == was);
    ocpl_r = 1;
    @(posedge clk); @(negedge clk); ocpl_r = 0;
    while (ocpl_v) @(negedge clk);
    if (st != APU_VGPU_DRW_OK)
      check($sformatf("%s kept", name), dbound == was);
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
    qreq_v = 0;
    qcpl_r = 0;
    ireq_v = 0;
    icpl_r = 0;
    rreq_v = 0;
    rcpl_r = 0;
    xreq_v = 0;
    xcpl_r = 0;
    yreq_v = 0;
    ycpl_r = 0;
    preq_v = 0;
    pcpl_r = 0;
    greq_v = 0;
    gcpl_r = 0;
    hreq_v = 0;
    hcpl_r = 0;
    oreq_v = 0;
    ocpl_r = 0;
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
    check("off stays quiet", off_rdy == 0 && off_v == 0 && oreq_rdy == 1 && dbound == '0);
    check("profiles keep tail off",
          !ApuOff.VpEn && !ApuOff.FboEn && !ApuOff.ClrEn && !ApuOff.DrwEn &&
          !ApuP1Transport.VpEn && !ApuP1Transport.FboEn && !ApuP1Transport.ClrEn &&
          !ApuP1Transport.DrwEn && !ApuHarness.VpEn && !ApuHarness.FboEn &&
          !ApuHarness.ClrEn && !ApuHarness.DrwEn && !ApuSchedBoth.VpEn &&
          !ApuSchedBoth.FboEn && !ApuSchedBoth.ClrEn && !ApuSchedBoth.DrwEn &&
          !ApuBadVirglGrant.VpEn && !ApuBadVirglGrant.FboEn &&
          !ApuBadVirglGrant.ClrEn && !ApuBadVirglGrant.DrwEn);
    cfg = ApuP1Transport;
    cfg.VpEn = 1'b1;
    cfg.FboEn = 1'b1;
    cfg.ClrEn = 1'b1;
    cfg.DrwEn = 1'b1;
    check("tail does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.VpEn = 1'b1;
    cfg.FboEn = 1'b1;
    cfg.ClrEn = 1'b1;
    cfg.DrwEn = 1'b1;
    check("tail does not legalize virgl", !apu_cfg_legal(cfg));

    vp_step(APU_VGPU_VP_EMPTY, "empty vp");
    fbo_step(APU_VGPU_FBO_EMPTY, "empty fbo");
    clr_step(APU_VGPU_CLR_EMPTY, "empty clr");
    drw_step(APU_VGPU_DRW_EMPTY, "empty drw");

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
    veb_step(APU_VGPU_VEB_EMPTY, "surf veb");
    ssb_step(APU_VGPU_SSB_EMPTY, "surf ssb");
    svb_step(APU_VGPU_SVB_EMPTY, "surf svb");
    iw_step(APU_VGPU_IW_EMPTY, "surf iw");
    vb_step(APU_VGPU_VB_EMPTY, "surf vb");
    sci_step(APU_VGPU_SCI_EMPTY, "surf sci");
    vp_step(APU_VGPU_VP_EMPTY, "surf vp");
    fbo_step(APU_VGPU_FBO_EMPTY, "surf fbo");
    clr_step(APU_VGPU_CLR_EMPTY, "surf clr");
    drw_step(APU_VGPU_DRW_EMPTY, "surf drw");
    check("before clear", dbound == '0);

    pulse_reset();
    img = 5;
    load_buf(32'd824, "vp room load");
    dec_step("vp room dec");
    sh_step(APU_VGPU_SH_OK, "vp room sh");
    fs_step(APU_VGPU_SH_OK, "vp room fs");
    ve_step(APU_VGPU_VE_OK, "vp room ve");
    sv_step(APU_VGPU_SV_OK, "vp room sv");
    ss_step(APU_VGPU_SS_OK, "vp room ss");
    bl_step(APU_VGPU_BL_OK, "vp room bl");
    ds_step(APU_VGPU_DS_OK, "vp room ds");
    rz_step(APU_VGPU_RZ_OK, "vp room rz");
    bb_step(APU_VGPU_BB_OK, "vp room bb");
    db_step(APU_VGPU_DB_OK, "vp room db");
    rb_step(APU_VGPU_RB_OK, "vp room rb");
    vsb_step(APU_VGPU_VSB_OK, "vp room vsb");
    fsb_step(APU_VGPU_FSB_OK, "vp room fsb");
    veb_step(APU_VGPU_VEB_OK, "vp room veb");
    ssb_step(APU_VGPU_SSB_OK, "vp room ssb");
    svb_step(APU_VGPU_SVB_OK, "vp room svb");
    iw_step(APU_VGPU_IW_OK, "vp room iw");
    vb_step(APU_VGPU_VB_OK, "vp room vb");
    sci_step(APU_VGPU_SCI_OK, "vp room sci");
    check("sci parked", sbox.valid && sbox.next == 32'd824 &&
          sbox.width == 16'd640 && sbox.height == 16'd480);
    vp_step(APU_VGPU_VP_FAULT, "vp no room");
    check("vp room clear", vpbound == '0);

    pulse_reset();
    img = 1;
    load_buf(32'd832, "vp count load");
    dec_step("vp count dec");
    sh_step(APU_VGPU_SH_OK, "vp count sh");
    fs_step(APU_VGPU_SH_OK, "vp count fs");
    ve_step(APU_VGPU_VE_OK, "vp count ve");
    sv_step(APU_VGPU_SV_OK, "vp count sv");
    ss_step(APU_VGPU_SS_OK, "vp count ss");
    bl_step(APU_VGPU_BL_OK, "vp count bl");
    ds_step(APU_VGPU_DS_OK, "vp count ds");
    rz_step(APU_VGPU_RZ_OK, "vp count rz");
    bb_step(APU_VGPU_BB_OK, "vp count bb");
    db_step(APU_VGPU_DB_OK, "vp count db");
    rb_step(APU_VGPU_RB_OK, "vp count rb");
    vsb_step(APU_VGPU_VSB_OK, "vp count vsb");
    fsb_step(APU_VGPU_FSB_OK, "vp count fsb");
    veb_step(APU_VGPU_VEB_OK, "vp count veb");
    ssb_step(APU_VGPU_SSB_OK, "vp count ssb");
    svb_step(APU_VGPU_SVB_OK, "vp count svb");
    iw_step(APU_VGPU_IW_OK, "vp count iw");
    vb_step(APU_VGPU_VB_OK, "vp count vb");
    sci_step(APU_VGPU_SCI_OK, "vp count sci");
    vp_step(APU_VGPU_VP_FAULT, "vp bad count");
    check("vp count clear", vpbound == '0);

    pulse_reset();
    img = 2;
    load_buf(32'd856, "vp scale load");
    dec_step("vp scale dec");
    sh_step(APU_VGPU_SH_OK, "vp scale sh");
    fs_step(APU_VGPU_SH_OK, "vp scale fs");
    ve_step(APU_VGPU_VE_OK, "vp scale ve");
    sv_step(APU_VGPU_SV_OK, "vp scale sv");
    ss_step(APU_VGPU_SS_OK, "vp scale ss");
    bl_step(APU_VGPU_BL_OK, "vp scale bl");
    ds_step(APU_VGPU_DS_OK, "vp scale ds");
    rz_step(APU_VGPU_RZ_OK, "vp scale rz");
    bb_step(APU_VGPU_BB_OK, "vp scale bb");
    db_step(APU_VGPU_DB_OK, "vp scale db");
    rb_step(APU_VGPU_RB_OK, "vp scale rb");
    vsb_step(APU_VGPU_VSB_OK, "vp scale vsb");
    fsb_step(APU_VGPU_FSB_OK, "vp scale fsb");
    veb_step(APU_VGPU_VEB_OK, "vp scale veb");
    ssb_step(APU_VGPU_SSB_OK, "vp scale ssb");
    svb_step(APU_VGPU_SVB_OK, "vp scale svb");
    iw_step(APU_VGPU_IW_OK, "vp scale iw");
    vb_step(APU_VGPU_VB_OK, "vp scale vb");
    sci_step(APU_VGPU_SCI_OK, "vp scale sci");
    vp_step(APU_VGPU_VP_FAULT, "vp bad scale");
    check("vp scale clear", vpbound == '0);

    pulse_reset();
    img = 6;
    load_buf(32'd856, "fbo room load");
    dec_step("fbo room dec");
    sh_step(APU_VGPU_SH_OK, "fbo room sh");
    fs_step(APU_VGPU_SH_OK, "fbo room fs");
    ve_step(APU_VGPU_VE_OK, "fbo room ve");
    sv_step(APU_VGPU_SV_OK, "fbo room sv");
    ss_step(APU_VGPU_SS_OK, "fbo room ss");
    bl_step(APU_VGPU_BL_OK, "fbo room bl");
    ds_step(APU_VGPU_DS_OK, "fbo room ds");
    rz_step(APU_VGPU_RZ_OK, "fbo room rz");
    bb_step(APU_VGPU_BB_OK, "fbo room bb");
    db_step(APU_VGPU_DB_OK, "fbo room db");
    rb_step(APU_VGPU_RB_OK, "fbo room rb");
    vsb_step(APU_VGPU_VSB_OK, "fbo room vsb");
    fsb_step(APU_VGPU_FSB_OK, "fbo room fsb");
    veb_step(APU_VGPU_VEB_OK, "fbo room veb");
    ssb_step(APU_VGPU_SSB_OK, "fbo room ssb");
    svb_step(APU_VGPU_SVB_OK, "fbo room svb");
    iw_step(APU_VGPU_IW_OK, "fbo room iw");
    vb_step(APU_VGPU_VB_OK, "fbo room vb");
    sci_step(APU_VGPU_SCI_OK, "fbo room sci");
    vp_step(APU_VGPU_VP_OK, "fbo room vp");
    check("vp parked", vpbound.valid && vpbound.next == 32'd856 &&
          vpbound.scale_x == APU_VIRGL_F32_HALF_W &&
          vpbound.scale_y == APU_VIRGL_F32_HALF_H);
    fbo_step(APU_VGPU_FBO_FAULT, "fbo no room");
    check("fbo room clear", fbound == '0);

    pulse_reset();
    img = 7;
    load_buf(32'd864, "fbo count load");
    dec_step("fbo count dec");
    sh_step(APU_VGPU_SH_OK, "fbo count sh");
    fs_step(APU_VGPU_SH_OK, "fbo count fs");
    ve_step(APU_VGPU_VE_OK, "fbo count ve");
    sv_step(APU_VGPU_SV_OK, "fbo count sv");
    ss_step(APU_VGPU_SS_OK, "fbo count ss");
    bl_step(APU_VGPU_BL_OK, "fbo count bl");
    ds_step(APU_VGPU_DS_OK, "fbo count ds");
    rz_step(APU_VGPU_RZ_OK, "fbo count rz");
    bb_step(APU_VGPU_BB_OK, "fbo count bb");
    db_step(APU_VGPU_DB_OK, "fbo count db");
    rb_step(APU_VGPU_RB_OK, "fbo count rb");
    vsb_step(APU_VGPU_VSB_OK, "fbo count vsb");
    fsb_step(APU_VGPU_FSB_OK, "fbo count fsb");
    veb_step(APU_VGPU_VEB_OK, "fbo count veb");
    ssb_step(APU_VGPU_SSB_OK, "fbo count ssb");
    svb_step(APU_VGPU_SVB_OK, "fbo count svb");
    iw_step(APU_VGPU_IW_OK, "fbo count iw");
    vb_step(APU_VGPU_VB_OK, "fbo count vb");
    sci_step(APU_VGPU_SCI_OK, "fbo count sci");
    vp_step(APU_VGPU_VP_OK, "fbo count vp");
    fbo_step(APU_VGPU_FBO_FAULT, "fbo bad count");
    check("fbo count clear", fbound == '0);

    pulse_reset();
    img = 8;
    load_buf(32'd872, "fbo surf load");
    dec_step("fbo surf dec");
    sh_step(APU_VGPU_SH_OK, "fbo surf sh");
    fs_step(APU_VGPU_SH_OK, "fbo surf fs");
    ve_step(APU_VGPU_VE_OK, "fbo surf ve");
    sv_step(APU_VGPU_SV_OK, "fbo surf sv");
    ss_step(APU_VGPU_SS_OK, "fbo surf ss");
    bl_step(APU_VGPU_BL_OK, "fbo surf bl");
    ds_step(APU_VGPU_DS_OK, "fbo surf ds");
    rz_step(APU_VGPU_RZ_OK, "fbo surf rz");
    bb_step(APU_VGPU_BB_OK, "fbo surf bb");
    db_step(APU_VGPU_DB_OK, "fbo surf db");
    rb_step(APU_VGPU_RB_OK, "fbo surf rb");
    vsb_step(APU_VGPU_VSB_OK, "fbo surf vsb");
    fsb_step(APU_VGPU_FSB_OK, "fbo surf fsb");
    veb_step(APU_VGPU_VEB_OK, "fbo surf veb");
    ssb_step(APU_VGPU_SSB_OK, "fbo surf ssb");
    svb_step(APU_VGPU_SVB_OK, "fbo surf svb");
    iw_step(APU_VGPU_IW_OK, "fbo surf iw");
    vb_step(APU_VGPU_VB_OK, "fbo surf vb");
    sci_step(APU_VGPU_SCI_OK, "fbo surf sci");
    vp_step(APU_VGPU_VP_OK, "fbo surf vp");
    fbo_step(APU_VGPU_FBO_FAULT, "fbo bad surface");
    check("fbo surf clear", fbound == '0);

    pulse_reset();
    img = 9;
    load_buf(32'd872, "clr room load");
    dec_step("clr room dec");
    sh_step(APU_VGPU_SH_OK, "clr room sh");
    fs_step(APU_VGPU_SH_OK, "clr room fs");
    ve_step(APU_VGPU_VE_OK, "clr room ve");
    sv_step(APU_VGPU_SV_OK, "clr room sv");
    ss_step(APU_VGPU_SS_OK, "clr room ss");
    bl_step(APU_VGPU_BL_OK, "clr room bl");
    ds_step(APU_VGPU_DS_OK, "clr room ds");
    rz_step(APU_VGPU_RZ_OK, "clr room rz");
    bb_step(APU_VGPU_BB_OK, "clr room bb");
    db_step(APU_VGPU_DB_OK, "clr room db");
    rb_step(APU_VGPU_RB_OK, "clr room rb");
    vsb_step(APU_VGPU_VSB_OK, "clr room vsb");
    fsb_step(APU_VGPU_FSB_OK, "clr room fsb");
    veb_step(APU_VGPU_VEB_OK, "clr room veb");
    ssb_step(APU_VGPU_SSB_OK, "clr room ssb");
    svb_step(APU_VGPU_SVB_OK, "clr room svb");
    iw_step(APU_VGPU_IW_OK, "clr room iw");
    vb_step(APU_VGPU_VB_OK, "clr room vb");
    sci_step(APU_VGPU_SCI_OK, "clr room sci");
    vp_step(APU_VGPU_VP_OK, "clr room vp");
    fbo_step(APU_VGPU_FBO_OK, "clr room fbo");
    check("fbo parked", fbound.valid && fbound.next == 32'd872 &&
          fbound.nr_cbufs == 32'd1 && fbound.surface == APU_VIRGL_SURFACE_HANDLE);
    clr_step(APU_VGPU_CLR_FAULT, "clr no room");
    check("clr room clear", cbound == '0);

    pulse_reset();
    img = 10;
    load_buf(32'd880, "clr count load");
    dec_step("clr count dec");
    sh_step(APU_VGPU_SH_OK, "clr count sh");
    fs_step(APU_VGPU_SH_OK, "clr count fs");
    ve_step(APU_VGPU_VE_OK, "clr count ve");
    sv_step(APU_VGPU_SV_OK, "clr count sv");
    ss_step(APU_VGPU_SS_OK, "clr count ss");
    bl_step(APU_VGPU_BL_OK, "clr count bl");
    ds_step(APU_VGPU_DS_OK, "clr count ds");
    rz_step(APU_VGPU_RZ_OK, "clr count rz");
    bb_step(APU_VGPU_BB_OK, "clr count bb");
    db_step(APU_VGPU_DB_OK, "clr count db");
    rb_step(APU_VGPU_RB_OK, "clr count rb");
    vsb_step(APU_VGPU_VSB_OK, "clr count vsb");
    fsb_step(APU_VGPU_FSB_OK, "clr count fsb");
    veb_step(APU_VGPU_VEB_OK, "clr count veb");
    ssb_step(APU_VGPU_SSB_OK, "clr count ssb");
    svb_step(APU_VGPU_SVB_OK, "clr count svb");
    iw_step(APU_VGPU_IW_OK, "clr count iw");
    vb_step(APU_VGPU_VB_OK, "clr count vb");
    sci_step(APU_VGPU_SCI_OK, "clr count sci");
    vp_step(APU_VGPU_VP_OK, "clr count vp");
    fbo_step(APU_VGPU_FBO_OK, "clr count fbo");
    clr_step(APU_VGPU_CLR_FAULT, "clr bad count");
    check("clr count clear", cbound == '0);

    pulse_reset();
    img = 11;
    load_buf(32'd908, "clr color load");
    dec_step("clr color dec");
    sh_step(APU_VGPU_SH_OK, "clr color sh");
    fs_step(APU_VGPU_SH_OK, "clr color fs");
    ve_step(APU_VGPU_VE_OK, "clr color ve");
    sv_step(APU_VGPU_SV_OK, "clr color sv");
    ss_step(APU_VGPU_SS_OK, "clr color ss");
    bl_step(APU_VGPU_BL_OK, "clr color bl");
    ds_step(APU_VGPU_DS_OK, "clr color ds");
    rz_step(APU_VGPU_RZ_OK, "clr color rz");
    bb_step(APU_VGPU_BB_OK, "clr color bb");
    db_step(APU_VGPU_DB_OK, "clr color db");
    rb_step(APU_VGPU_RB_OK, "clr color rb");
    vsb_step(APU_VGPU_VSB_OK, "clr color vsb");
    fsb_step(APU_VGPU_FSB_OK, "clr color fsb");
    veb_step(APU_VGPU_VEB_OK, "clr color veb");
    ssb_step(APU_VGPU_SSB_OK, "clr color ssb");
    svb_step(APU_VGPU_SVB_OK, "clr color svb");
    iw_step(APU_VGPU_IW_OK, "clr color iw");
    vb_step(APU_VGPU_VB_OK, "clr color vb");
    sci_step(APU_VGPU_SCI_OK, "clr color sci");
    vp_step(APU_VGPU_VP_OK, "clr color vp");
    fbo_step(APU_VGPU_FBO_OK, "clr color fbo");
    clr_step(APU_VGPU_CLR_FAULT, "clr bad color");
    check("clr color clear", cbound == '0);

    pulse_reset();
    img = 12;
    load_buf(32'd908, "drw room load");
    dec_step("drw room dec");
    sh_step(APU_VGPU_SH_OK, "drw room sh");
    fs_step(APU_VGPU_SH_OK, "drw room fs");
    ve_step(APU_VGPU_VE_OK, "drw room ve");
    sv_step(APU_VGPU_SV_OK, "drw room sv");
    ss_step(APU_VGPU_SS_OK, "drw room ss");
    bl_step(APU_VGPU_BL_OK, "drw room bl");
    ds_step(APU_VGPU_DS_OK, "drw room ds");
    rz_step(APU_VGPU_RZ_OK, "drw room rz");
    bb_step(APU_VGPU_BB_OK, "drw room bb");
    db_step(APU_VGPU_DB_OK, "drw room db");
    rb_step(APU_VGPU_RB_OK, "drw room rb");
    vsb_step(APU_VGPU_VSB_OK, "drw room vsb");
    fsb_step(APU_VGPU_FSB_OK, "drw room fsb");
    veb_step(APU_VGPU_VEB_OK, "drw room veb");
    ssb_step(APU_VGPU_SSB_OK, "drw room ssb");
    svb_step(APU_VGPU_SVB_OK, "drw room svb");
    iw_step(APU_VGPU_IW_OK, "drw room iw");
    vb_step(APU_VGPU_VB_OK, "drw room vb");
    sci_step(APU_VGPU_SCI_OK, "drw room sci");
    vp_step(APU_VGPU_VP_OK, "drw room vp");
    fbo_step(APU_VGPU_FBO_OK, "drw room fbo");
    clr_step(APU_VGPU_CLR_OK, "drw room clr");
    check("clr parked", cbound.valid && cbound.next == 32'd908 &&
          cbound.buffers == APU_VIRGL_CLEAR_COLOR &&
          cbound.red == APU_VIRGL_F32_P05 && cbound.alpha == APU_VIRGL_F32_ONE);
    drw_step(APU_VGPU_DRW_FAULT, "drw no room");
    check("drw room clear", dbound == '0);

    pulse_reset();
    img = 13;
    load_buf(32'd916, "drw count load");
    dec_step("drw count dec");
    sh_step(APU_VGPU_SH_OK, "drw count sh");
    fs_step(APU_VGPU_SH_OK, "drw count fs");
    ve_step(APU_VGPU_VE_OK, "drw count ve");
    sv_step(APU_VGPU_SV_OK, "drw count sv");
    ss_step(APU_VGPU_SS_OK, "drw count ss");
    bl_step(APU_VGPU_BL_OK, "drw count bl");
    ds_step(APU_VGPU_DS_OK, "drw count ds");
    rz_step(APU_VGPU_RZ_OK, "drw count rz");
    bb_step(APU_VGPU_BB_OK, "drw count bb");
    db_step(APU_VGPU_DB_OK, "drw count db");
    rb_step(APU_VGPU_RB_OK, "drw count rb");
    vsb_step(APU_VGPU_VSB_OK, "drw count vsb");
    fsb_step(APU_VGPU_FSB_OK, "drw count fsb");
    veb_step(APU_VGPU_VEB_OK, "drw count veb");
    ssb_step(APU_VGPU_SSB_OK, "drw count ssb");
    svb_step(APU_VGPU_SVB_OK, "drw count svb");
    iw_step(APU_VGPU_IW_OK, "drw count iw");
    vb_step(APU_VGPU_VB_OK, "drw count vb");
    sci_step(APU_VGPU_SCI_OK, "drw count sci");
    vp_step(APU_VGPU_VP_OK, "drw count vp");
    fbo_step(APU_VGPU_FBO_OK, "drw count fbo");
    clr_step(APU_VGPU_CLR_OK, "drw count clr");
    drw_step(APU_VGPU_DRW_FAULT, "drw bad count");
    check("drw count clear", dbound == '0);

    pulse_reset();
    img = 14;
    load_buf(32'd960, "drw prim load");
    dec_step("drw prim dec");
    sh_step(APU_VGPU_SH_OK, "drw prim sh");
    fs_step(APU_VGPU_SH_OK, "drw prim fs");
    ve_step(APU_VGPU_VE_OK, "drw prim ve");
    sv_step(APU_VGPU_SV_OK, "drw prim sv");
    ss_step(APU_VGPU_SS_OK, "drw prim ss");
    bl_step(APU_VGPU_BL_OK, "drw prim bl");
    ds_step(APU_VGPU_DS_OK, "drw prim ds");
    rz_step(APU_VGPU_RZ_OK, "drw prim rz");
    bb_step(APU_VGPU_BB_OK, "drw prim bb");
    db_step(APU_VGPU_DB_OK, "drw prim db");
    rb_step(APU_VGPU_RB_OK, "drw prim rb");
    vsb_step(APU_VGPU_VSB_OK, "drw prim vsb");
    fsb_step(APU_VGPU_FSB_OK, "drw prim fsb");
    veb_step(APU_VGPU_VEB_OK, "drw prim veb");
    ssb_step(APU_VGPU_SSB_OK, "drw prim ssb");
    svb_step(APU_VGPU_SVB_OK, "drw prim svb");
    iw_step(APU_VGPU_IW_OK, "drw prim iw");
    vb_step(APU_VGPU_VB_OK, "drw prim vb");
    sci_step(APU_VGPU_SCI_OK, "drw prim sci");
    vp_step(APU_VGPU_VP_OK, "drw prim vp");
    fbo_step(APU_VGPU_FBO_OK, "drw prim fbo");
    clr_step(APU_VGPU_CLR_OK, "drw prim clr");
    drw_step(APU_VGPU_DRW_FAULT, "drw bad prim");
    check("drw prim clear", dbound == '0);

    pulse_reset();
    img = 3;
    load_buf(32'd960, "draw load");
    dec_step("draw dec");
    sh_step(APU_VGPU_SH_OK, "draw sh");
    fs_step(APU_VGPU_SH_OK, "draw fs");
    ve_step(APU_VGPU_VE_OK, "draw ve");
    sv_step(APU_VGPU_SV_OK, "draw sv");
    ss_step(APU_VGPU_SS_OK, "draw ss");
    bl_step(APU_VGPU_BL_OK, "draw bl");
    ds_step(APU_VGPU_DS_OK, "draw ds");
    rz_step(APU_VGPU_RZ_OK, "draw rz");
    bb_step(APU_VGPU_BB_OK, "draw bb");
    db_step(APU_VGPU_DB_OK, "draw db");
    rb_step(APU_VGPU_RB_OK, "draw rb");
    vsb_step(APU_VGPU_VSB_OK, "draw vsb");
    fsb_step(APU_VGPU_FSB_OK, "draw fsb");
    veb_step(APU_VGPU_VEB_OK, "draw veb");
    ssb_step(APU_VGPU_SSB_OK, "draw ssb");
    svb_step(APU_VGPU_SVB_OK, "draw svb");
    iw_step(APU_VGPU_IW_OK, "draw iw");
    vb_step(APU_VGPU_VB_OK, "draw vb");
    sci_step(APU_VGPU_SCI_OK, "draw sci");
    vp_step(APU_VGPU_VP_OK, "draw vp");
    fbo_step(APU_VGPU_FBO_OK, "draw fbo");
    clr_step(APU_VGPU_CLR_OK, "draw clr");
    drw_step(APU_VGPU_DRW_OK, "draw");
    check("draw id", dbound.valid && dbound.count == APU_VIRGL_VERT_COUNT &&
          dbound.prim == APU_VIRGL_PRIM_STRIP && dbound.next == 32'd960);
    check("clr stays", cbound.valid && cbound.red == APU_VIRGL_F32_P05 &&
          cbound.green == APU_VIRGL_F32_P05 && cbound.blue == APU_VIRGL_F32_P10 &&
          cbound.next == 32'd908);
    drw_step(APU_VGPU_DRW_FAULT, "second");
    check("second keeps", dbound.valid && dbound.count == APU_VIRGL_VERT_COUNT &&
          dbound.prim == APU_VIRGL_PRIM_STRIP && dbound.next == 32'd960);

    if (errors != 0) $fatal(1, "APU vgpu tail errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_tail cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
