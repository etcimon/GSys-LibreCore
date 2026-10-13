// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Direct-drive smoke bench for the raster engine (G1b first-pixel).
// The DUT is driven by an apu_rast_draw_t record; a TB-side shader
// stub answers the ShaderCore work port (VS: Position = {attr0.x,
// attr0.y, 0.5, 1.0} and varying loc0 = attr1; FS: color loc0 =
// FS-in loc0), a vgpages stub returns a fixed private base, and
// tb_apu_mp_mem backs the aperture.
//
//   case 1  CLEAR 32x32 R8G8B8A8 to (0.25, 0.5, 0.75, 1.0)
//   case 2  one triangle (front) with per-vertex colors, cull BACK —
//           every pixel vs an SV reference (same 16.8 edge functions,
//           same top-left rule, linear barycentrics since w=1), 1 LSB
//   case 3  same triangle wound back — fully culled, fb = fresh clear
//   case 3b same negative-shoelace winding declared CCW-front — the
//           internal v1/v2 swap must carry the varying records with it
//   case 4  two-triangle strip quad + scissor — only the scissor
//           region may be written
//   case 5  B8G8R8A8_SRGB flat colour — sRGB LUT encode + BGR order
//   case 6  SRC_ALPHA/ONE_MINUS_SRC_ALPHA blend, RGB-only mask —
//           dst alpha preserved
//   case 7  two overlapping triangles, D32 depth, LESS + write —
//           nearer wins, depth words checked
//   case 8  UINT16 indexed quad, vertexOffset 2, instance-rate
//           colour attr, 2 instances
//   case 9  clip-space clip: one vertex behind the camera (w<0) and
//           one past the far plane — coverage vs a double-precision
//           clip+raster reference, exact >=1px from clip edges, <=2%
//           mismatches allowed along them (count printed)
//   case 10 thin triangle: partially covered 2x2 quads — only
//           covered pixels may be written (helper lanes never reach
//           the ROP), exact coverage
//   case 11 SRC_ALPHA/ONE_MINUS_SRC_ALPHA on colour AND alpha with
//           full write mask — the vkcmp blend_layers configuration:
//           dst alpha is consumed and overwritten by the blend
module tb_g6lc_apu_rast;
  import g6lc_apu_mp_pkg::*;
  import g6lc_apu_cmdexec_pkg::*;
  import g6lc_apu_sh_pkg::*;
  import g6lc_apu_rast_pkg::*;
  import g6lc_apu_srgb_pkg::*;
  import g6lc_apu_vgpages_pkg::*;
  import g6lc_apu_vn_pkg::*;

  int checks = 0, cases = 0, fails = 0;
  longint cyc = 0, c0;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  always_ff @(posedge clk) cyc <= cyc + 1;

  // ---- aperture layout --------------------------------------------------
  localparam int unsigned APW  = 32'h40000;   // 1 MiB dense window
  localparam int unsigned PWB  = 32'h40000;   // private arena word base
  localparam int unsigned PPW  = 32'h08000;   // 128 KiB private window
  localparam int unsigned FB   = 32'h0001000; // framebuffer byte base
  localparam int unsigned DB   = 32'h0008000; // depth buffer byte base
  localparam int unsigned VB   = 32'h0010000; // vertex buffer byte base
  localparam int unsigned PG_BASE = 32'h100000; // ALLOC_PRIV result
  localparam int unsigned FBP  = 32'd128;     // row pitch (align(32*4,64))

  // ---- DUT wiring ---------------------------------------------------------
  logic               w_v, w_r, w_done;
  apu_cmdexec_work_t  w_o = '0;
  apu_rast_draw_t     rd = '0;
  apu_sh_done_t       w_dpl;
  logic               shv, shr;
  logic [31:0]        shc;
  logic [7:0][31:0]   shim;
  logic [2:0]         shslot;
  apu_sh_desc_t       shdesc;
  logic [5:0]         shpn;
  logic [1023:0]      shpush;
  logic               shdone;
  apu_sh_done_t       shdone_pl;
  logic               mpv, mpr, mpsv;
  apu_mp_req_t        mpreq;
  apu_mp_rsp_t        mprsp;
  logic               pgv, pgr, pgcv, pgcr;
  apu_vgpages_req_t   pgreq;
  apu_vgpages_cpl_t   pgcpl;
  logic               rbusy;

  g6lc_apu_rast #(.Enable(1'b1)) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .work_valid_i(w_v), .work_ready_o(w_r),
    .work_i(w_o), .rd_i(rd),
    .desc_i('0), .push_n_i('0), .push_i('0),
    .done_o(w_done), .done_pl_o(w_dpl),
    .sh_work_valid_o(shv), .sh_work_ready_i(shr),
    .sh_ctype_o(shc), .sh_imm_o(shim), .sh_slot_o(shslot),
    .sh_desc_o(shdesc), .sh_push_n_o(shpn), .sh_push_o(shpush),
    .sh_done_i(shdone), .sh_done_pl_i(shdone_pl),
    .mp_req_valid_o(mpv), .mp_req_ready_i(mpr),
    .mp_req_o(mpreq),
    .mp_rsp_valid_i(mpsv), .mp_rsp_i(mprsp),
    .pg_req_valid_o(pgv), .pg_req_ready_i(pgr), .pg_req_o(pgreq),
    .pg_cpl_valid_i(pgcv), .pg_cpl_ready_o(pgcr), .pg_cpl_i(pgcpl),
    .busy_o(rbusy));

  tb_apu_mp_mem #(.N(1), .GMW(16), .APW(APW),
                  .PWB(PWB), .PPW(PPW)) i_mem (
    .clk_i(clk), .rst_ni(rst_n),
    .req_valid_i(mpv), .req_ready_o(mpr), .req_i('{mpreq}),
    .rsp_valid_o(mpsv), .rsp_o('{mprsp}));

  // ---- vgpages stub: one ALLOC_PRIV answer, fixed base -------------------
  assign pgr = 1'b1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pgcv <= 1'b0; pgcpl <= '0;
    end else begin
      if (pgv && pgr) begin
        pgcv  <= 1'b1;
        pgcpl <= '{status: APU_VGPAGES_OK, base: PG_BASE};
      end else if (pgcv && pgcr)
        pgcv <= 1'b0;
    end
  end

  // ---- shader stub ---------------------------------------------------------
  // Accepts each wave after a short delay, materialises the output
  // records straight into the backing store (the DUT reads them back
  // over the mp port), then pulses done.
  typedef enum logic [1:0] { SH_IDLE, SH_RUN, SH_DONE } shst_e;
  shst_e       shst = SH_IDLE;
  logic [31:0] sh_ctype_q;
  logic [7:0][31:0] sh_imm_q;
  int unsigned sh_i;
  int unsigned sh_n;
  logic        sh_pos4 = 1'b0;   // 1: VS Position := loc0 verbatim

  assign shr = shst == SH_IDLE;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shst <= SH_IDLE; shdone <= 1'b0; shdone_pl <= '0;
      sh_ctype_q <= '0; sh_imm_q <= '0; sh_i <= 0; sh_n <= 0;
    end else begin
      shdone <= 1'b0;
      unique case (shst)
        SH_IDLE: begin
          if (shv && shr) begin
            sh_ctype_q <= shc;
            sh_imm_q <= shim;
            sh_n <= int'(shim[0]);
            sh_i <= 0;
            shst <= SH_RUN;
          end
        end
        SH_RUN: begin
          if (sh_ctype_q == APU_SH_WORK_VS) begin
            // Position = {attr0.x, attr0.y, 0.5, 1.0} — or the raw
            // clip-space Position = loc0 when sh_pos4 (case 9);
            // varying loc0 = attr1 (vec4 at in+16)
            automatic int unsigned ib = int'(sh_imm_q[1]);
            automatic int unsigned ob = int'(sh_imm_q[2]);
            automatic int unsigned v  = sh_i;
            if (sh_pos4) begin
              for (int c = 0; c < 4; c++)
                i_mem.apm[apix((ob + v*144 + 4*c) >> 2)] <=
                  i_mem.apm[apix((ib + v*144 + 4*c) >> 2)];
            end else begin
              i_mem.apm[apix((ob + v*144 + 0) >> 2)] <=
                i_mem.apm[apix((ib + v*144 + 0) >> 2)];
              i_mem.apm[apix((ob + v*144 + 4) >> 2)] <=
                i_mem.apm[apix((ib + v*144 + 4) >> 2)];
              // Position.z = attr1.w (lets a case steer early-Z
              // through the per-vertex colour alpha); w = 1.0
              i_mem.apm[apix((ob + v*144 + 8) >> 2)] <=
                i_mem.apm[apix((ib + v*144 + 28) >> 2)];
              i_mem.apm[apix((ob + v*144 + 12) >> 2)] <=
                32'h3F800000;
            end
            for (int c = 0; c < 4; c++)
              i_mem.apm[apix((ob + v*144 + 16 + 4*c) >> 2)] <=
                i_mem.apm[apix((ib + v*144 + 16 + 4*c) >> 2)];
          end else begin
            // FS: fs_out[f].loc0 = fs_in[f].loc0 (varying slot at +16)
            automatic int unsigned ib = int'(sh_imm_q[1]);
            automatic int unsigned ob = int'(sh_imm_q[2]);
            automatic int unsigned f  = sh_i;
            for (int c = 0; c < 4; c++)
              i_mem.apm[apix((ob + f*144 + 4*c) >> 2)] <=
                i_mem.apm[apix((ib + f*144 + 16 + 4*c) >> 2)];
          end
          if (sh_i + 1 >= sh_n) shst <= SH_DONE;
          else sh_i <= sh_i + 1;
        end
        SH_DONE: begin
          shdone <= 1'b1;
          shdone_pl <= '{code: APU_SH_DONE_OK, wave: '0, pc: '0,
                         robust: '0, work_id: sh_ctype_q};
          shst <= SH_IDLE;
        end
        default: shst <= SH_IDLE;
      endcase
    end
  end

  // ---- helpers --------------------------------------------------------------
  // local mirror of tb_apu_mp_mem's compressed aperture index:
  // [0,APW) dense, [PWB,PWB+PPW) packed at [APW,APW+PPW)
  function automatic int unsigned apix(input int unsigned w);
    if (w < APW) return w;
    if (w >= PWB && w < PWB + PPW) return APW + (w - PWB);
    $fatal(1, "aperture word %0d past dense model", w);
    return 0;
  endfunction

  function automatic int unsigned apw_i(input int unsigned byt);
    return apix(byt >> 2);
  endfunction

  // fb pixel {a,b,g,r} packed (R8G8B8A8_UNORM, little-endian byte order)
  function automatic logic [31:0] fbpx(input int x, input int y);
    return i_mem.apm[apw_i(FB + y*FBP + x*4)];
  endfunction

  // depth word (D32) at pixel
  function automatic logic [31:0] dbpx(input int x, input int y);
    return i_mem.apm[apw_i(DB + y*FBP + x*4)];
  endfunction

  // fp32 -> 12-bit linear index (mirror of the DUT's f_f32_u12, used
  // to pick the expected APU_SRGB_ENC entry)
  function automatic logic [11:0] f_u12(input logic [31:0] f);
    logic [39:0] p;
    logic [8:0]  sh;
    p  = 40'({1'b1, f[22:0]}) * 40'd4095;
    sh = 9'd150 - {1'b0, f[30:23]};
    if (f[31])              return 12'h000;
    if (f[30:23] == 8'h00)  return 12'h000;
    if (f[30:23] >= 8'd127) return 12'hFFF;
    return 12'((p + (40'h1 << (sh - 9'd1))) >> sh);
  endfunction

  // per-byte compare with ±tol; returns 1 on any channel off
  function automatic logic px_bad(input logic [31:0] got,
                                  input logic [31:0] exp,
                                  input int tol);
    for (int c = 0; c < 4; c++) begin
      automatic int dv = int'(got[8*c +: 8]) - int'(exp[8*c +: 8]);
      if (dv < -tol || dv > tol) return 1'b1;
    end
    return 1'b0;
  endfunction

  task automatic apwr(input int unsigned byt, input logic [31:0] v);
    i_mem.apm[apw_i(byt)] = v;
  endtask

  task automatic fail(input string s);
    fails = fails + 1;
    $display("FAIL %s", s);
  endtask

  // submit one work record and wait for completion (cycle-bounded).
  // ready is combinational, so valid is held until a negedge where
  // ready is seen high (the accept is the following posedge), then
  // dropped at the next negedge.
  task automatic do_work(input apu_rast_draw_t d,
                         input logic [31:0] ctype);
    int t0 = 0;
    rd = d;
    w_o.ctype = ctype;
    // wait for the engine idle (ready is comb off st==IDLE, sampled
    // mid-cycle at negedge), then hold valid for exactly one posedge
    do @(negedge clk); while (!w_r);
    w_v = 1'b1;
    @(negedge clk) w_v = 1'b0;
    while (!w_done && t0 < 4000000) begin
      @(negedge clk); t0++;
    end
    if (!w_done) begin fail("work timeout"); return; end
  endtask

  // ---- reference rasterizer (same int math as the DUT) ----------------------
  // screen coords (16.8) and per-vertex color (float as real)
  int           ref_xi[3], ref_yi[3];
  real          ref_col[3][4];
  // per-pixel reference color -> packed pixel (RGBA order)
  function automatic logic [31:0] ref_px(input int px, input int py);
    int signed cx, cy;
    longint signed e[3], ar;
    logic [2:0] tl;
    int x0, x1, x2, y0, y1, y2;
    real l[3], cc[4];
    x0 = ref_xi[0]; x1 = ref_xi[1]; x2 = ref_xi[2];
    y0 = ref_yi[0]; y1 = ref_yi[1]; y2 = ref_yi[2];
    cx = px*256 + 128;
    cy = py*256 + 128;
    ar = longint'(x1-x0)*longint'(y2-y0) -
         longint'(x2-x0)*longint'(y1-y0);
    // same sign convention as the DUT: d × (P - anchor), interior
    // positive for a positive-area (post-swap) winding
    e[0] = longint'(x2-x1)*longint'(cy-y1) -
           longint'(y2-y1)*longint'(cx-x1);
    e[1] = longint'(x0-x2)*longint'(cy-y2) -
           longint'(y0-y2)*longint'(cx-x2);
    e[2] = longint'(x1-x0)*longint'(cy-y0) -
           longint'(y1-y0)*longint'(cx-x0);
    tl[0] = (y1 > y2) || (y1 == y2 && x1 < x2);
    tl[1] = (y2 > y0) || (y2 == y0 && x2 < x0);
    tl[2] = (y0 > y1) || (y0 == y1 && x0 < x1);
    if (!((e[0] > 0 || (e[0] == 0 && tl[0])) &&
          (e[1] > 0 || (e[1] == 0 && tl[1])) &&
          (e[2] > 0 || (e[2] == 0 && tl[2]))))
      return 32'hFFFF_FFFF;              // outside
    for (int k = 0; k < 3; k++)
      l[k] = real'(e[k]) / real'(ar);
    for (int c = 0; c < 4; c++) begin
      cc[c] = l[0]*ref_col[0][c] + l[1]*ref_col[1][c] +
              l[2]*ref_col[2][c];
      if (cc[c] < 0.0) cc[c] = 0.0;
      if (cc[c] > 1.0) cc[c] = 1.0;
    end
    return {8'($rtoi(cc[3]*255.0 + 0.5)),
            8'($rtoi(cc[2]*255.0 + 0.5)),
            8'($rtoi(cc[1]*255.0 + 0.5)),
            8'($rtoi(cc[0]*255.0 + 0.5))};
  endfunction

  // draw record skeleton for the smoke cases
  function automatic apu_rast_draw_t mk_draw();
    apu_rast_draw_t d = '0;
    d.op = APU_RAST_OP_DRAW;
    d.vs_slot = 3'd0; d.fs_slot = 3'd1;
    d.fs_in_mask = 8'h01;
    d.topology = 8'd3;
    d.cull = 2'b10;              // BACK
    // Vulkan face orientation: front under CW frontFace means a
    // POSITIVE framebuffer shoelace (the spec's signed area is the
    // negated shoelace).  The smoke geometry is wound that way, so
    // CW keeps every case's coverage identical.
    d.front_ccw = 1'b0;
    d.attr[0] = '{loc: 3'd0, binding: 2'd0,
                  fmt: APU_RAST_VF_RG32_SFLOAT, offset: 12'd0,
                  valid: 1'b1};
    d.attr[1] = '{loc: 3'd1, binding: 2'd0,
                  fmt: APU_RAST_VF_RGBA32_SFLOAT, offset: 12'd8,
                  valid: 1'b1};
    d.vb_base[0] = VB; d.vb_size[0] = 32'h10000; d.vb_stride[0] = 16'd24;
    d.ib_type = 2'd0;
    d.vp = '{x: 32'h00000000, y: 32'h00000000,
             w: 32'h42000000, h: 32'h42000000,   // 32.0
             minz: 32'h00000000, maxz: 32'h3F800000};
    d.sc_x = 0; d.sc_y = 0; d.sc_w = 16'd32; d.sc_h = 16'd32;
    d.ca[0] = '{base: FB, size: 32'h1000, w: 16'd32, h: 16'd32,
                fmt: 8'(APU_IMG_FMT_R8G8B8A8_UNORM), mips: 5'd1,
                layers: 10'd1, layer_bytes: 32'h1000};
    d.ca_valid = 4'h1;
    for (int i = 0; i < 4; i++) d.blend[i].mask = 4'hF;
    d.vertex_count = 3; d.instance_count = 1;
    return d;
  endfunction

  function automatic apu_rast_draw_t mk_clear();
    apu_rast_draw_t d = '0;
    d.op = APU_RAST_OP_CLEAR;
    d.ca[0] = '{base: FB, size: 32'h1000, w: 16'd32, h: 16'd32,
                fmt: 8'(APU_IMG_FMT_R8G8B8A8_UNORM), mips: 5'd1,
                layers: 10'd1, layer_bytes: 32'h1000};
    d.ca_valid = 4'h1;
    return d;
  endfunction

  // write one vertex {x,y} + {r,g,b,a} (f32 bit patterns) at vb index i
  task automatic put_vert(input int i,
                          input logic [31:0] x, input logic [31:0] y,
                          input logic [31:0] r, input logic [31:0] g,
                          input logic [31:0] b, input logic [31:0] a);
    apwr(VB + i*24 + 0,  x);
    apwr(VB + i*24 + 4,  y);
    apwr(VB + i*24 + 8,  r);
    apwr(VB + i*24 + 12, g);
    apwr(VB + i*24 + 16, b);
    apwr(VB + i*24 + 20, a);
  endtask

  // ---- G2b case-9 machinery -------------------------------------------------
  // fpnew issue counter: an op counts as clip work when its return
  // state stays inside the S_OC_*/S_CP_* block of the DUT's st_e
  // (S_OC_G1=110 .. S_CP_PDN=140 — keep in sync with g6lc_apu_rast.sv)
  int  clip_fpop = 0;
  bit  clip_arm = 1'b0;
  always_ff @(posedge clk)
    if (clip_arm && dut.gen_on.fp_iss_q &&
        dut.gen_on.fp_ret_q >= 8'd110 && dut.gen_on.fp_ret_q <= 8'd140)
      clip_fpop <= clip_fpop + 1;

`ifdef RAST_TRC
  logic [7:0] lst = 8'hFF;
  always_ff @(posedge clk) begin
    if (dut.gen_on.st_q != lst) begin
      $display("[ST] %0d st=%0d fret=%0d iss=%0d ce=%0d cn=%0d co=%0d cpl=%0d ceb=%0d cfan=%0d cpn=%0d",
               cyc, dut.gen_on.st_q, dut.gen_on.fp_ret_q,
               dut.gen_on.fp_iss_q, dut.gen_on.ce_q, dut.gen_on.cn_q,
               dut.gen_on.co_q, dut.gen_on.cpl_q, dut.gen_on.ceb_q,
               dut.gen_on.cfan_q, dut.gen_on.cpn_q);
      lst <= dut.gen_on.st_q;
    end
    if (dut.gen_on.st_q == 8'd113)
      $display("[OC] %0d oc=%b%b%b p0=%08x %08x %08x %08x p1=%08x %08x %08x %08x p2=%08x %08x %08x %08x clip=%0d cpm=%b",
               cyc, dut.gen_on.oc_q[0], dut.gen_on.oc_q[1],
               dut.gen_on.oc_q[2],
               dut.gen_on.pos_q[0][0], dut.gen_on.pos_q[0][1],
               dut.gen_on.pos_q[0][2], dut.gen_on.pos_q[0][3],
               dut.gen_on.pos_q[1][0], dut.gen_on.pos_q[1][1],
               dut.gen_on.pos_q[1][2], dut.gen_on.pos_q[1][3],
               dut.gen_on.pos_q[2][0], dut.gen_on.pos_q[2][1],
               dut.gen_on.pos_q[2][2], dut.gen_on.pos_q[2][3],
               dut.gen_on.clip_q, dut.gen_on.cpm_q);
  end
`endif

  // double-precision Sutherland–Hodgman mirror: same five planes and
  // signed distances as the RTL — near z>=0, far z<=w, w>=1e-5,
  // |x|<=4096w, |y|<=4096w
  real c9p[9][4];
  int  c9tag[9];      // plane+1 that produced the vertex (0 = original)
  int  c9n;

  function automatic real c9pd(input real p[4], input int pl);
    real ax, ay;
    ax = (p[0] < 0.0) ? -p[0] : p[0];
    ay = (p[1] < 0.0) ? -p[1] : p[1];
    case (pl)
      0:       c9pd = p[2];
      1:       c9pd = p[3] - p[2];
      2:       c9pd = p[3] - 1.0e-5;
      3:       c9pd = 4096.0*p[3] - ax;
      default: c9pd = 4096.0*p[3] - ay;
    endcase
  endfunction

  // round-to-nearest-even (the DUT's fpnew F2I mode)
  function automatic longint c9rne(input real x);
    real    fl, fr;
    longint lo;
    fl = $floor(x); fr = x - fl; lo = longint'(fl);
    if (fr > 0.5)      c9rne = lo + 1;
    else if (fr < 0.5) c9rne = lo;
    else               c9rne = (lo % 2 != 0) ? lo + 1 : lo;
  endfunction

  task automatic c9clip(input real v0[4], input real v1[4],
                        input real v2[4]);
    real ip[9][4], op[9][4];
    int  itg[9], otg[9];
    int  ni, no;
    bit  anyo;
    ni = 3;
    for (int c = 0; c < 4; c++) begin
      ip[0][c] = v0[c]; ip[1][c] = v1[c]; ip[2][c] = v2[c];
    end
    itg[0] = 0; itg[1] = 0; itg[2] = 0;
    for (int pl = 0; pl < 5; pl++) begin
      anyo = 1'b0;
      for (int i = 0; i < ni; i++)
        if (c9pd(ip[i], pl) < 0.0) anyo = 1'b1;
      if (anyo) begin
        no = 0;
        for (int i = 0; i < ni; i++) begin
          int  j;
          real da, db, t;
          j  = (i + 1 == ni) ? 0 : i + 1;
          da = c9pd(ip[i], pl); db = c9pd(ip[j], pl);
          if (da >= 0.0 && db >= 0.0) begin           // in->in: copy b
            for (int c = 0; c < 4; c++) op[no][c] = ip[j][c];
            otg[no] = itg[j]; no++;
          end else if (da >= 0.0) begin               // in->out: isect
            t = da/(da - db);
            for (int c = 0; c < 4; c++)
              op[no][c] = ip[i][c] + t*(ip[j][c] - ip[i][c]);
            otg[no] = pl + 1; no++;
          end else if (db >= 0.0) begin               // out->in: isect, b
            t = da/(da - db);
            for (int c = 0; c < 4; c++)
              op[no][c] = ip[i][c] + t*(ip[j][c] - ip[i][c]);
            otg[no] = pl + 1; no++;
            for (int c = 0; c < 4; c++) op[no][c] = ip[j][c];
            otg[no] = itg[j]; no++;
          end                                         // out->out: none
        end
        ni = no;
        for (int i = 0; i < ni; i++) begin
          for (int c = 0; c < 4; c++) ip[i][c] = op[i][c];
          itg[i] = otg[i];
        end
      end
    end
    c9n = ni;
    for (int i = 0; i < ni; i++) begin
      for (int c = 0; c < 4; c++) c9p[i][c] = ip[i][c];
      c9tag[i] = itg[i];
    end
  endtask

  // projected clip vertex in screen px (double): ndc -> 32x32 viewport
  function automatic real c9sx(input int i);
    return c9p[i][0]/c9p[i][3] * 16.0 + 16.0;
  endfunction
  function automatic real c9sy(input int i);
    return c9p[i][1]/c9p[i][3] * 16.0 + 16.0;
  endfunction

  // 1 if the pixel centre is covered by any fan tri — same edge-fn +
  // top-left convention as ref_px, on the double-projected clip verts
  function automatic bit c9cov(input int px, input int py);
    int cxx, cyy;
    cxx = px*256 + 128; cyy = py*256 + 128;
    c9cov = 1'b0;
    for (int f = 1; f + 1 < c9n; f++) begin
      longint signed e0, e1, e2;
      longint signed x0, y0, x1, y1, x2, y2;
      bit tl0, tl1, tl2;
      x0 = c9rne(c9sx(0)*256.0);   y0 = c9rne(c9sy(0)*256.0);
      x1 = c9rne(c9sx(f)*256.0);   y1 = c9rne(c9sy(f)*256.0);
      x2 = c9rne(c9sx(f+1)*256.0); y2 = c9rne(c9sy(f+1)*256.0);
      e0 = (x2-x1)*(cyy-y1) - (y2-y1)*(cxx-x1);
      e1 = (x0-x2)*(cyy-y2) - (y0-y2)*(cxx-x2);
      e2 = (x1-x0)*(cyy-y0) - (y1-y0)*(cxx-x0);
      tl0 = (y1 > y2) || (y1 == y2 && x1 < x2);
      tl1 = (y2 > y0) || (y2 == y0 && x2 < x0);
      tl2 = (y0 > y1) || (y0 == y1 && x0 < x1);
      if ((e0 > 0 || (e0 == 0 && tl0)) &&
          (e1 > 0 || (e1 == 0 && tl1)) &&
          (e2 > 0 || (e2 == 0 && tl2)))
        c9cov = 1'b1;
    end
  endfunction

  // 1 if the pixel centre lies within 1px of a polygon edge that the
  // clip produced or shortened (at least one endpoint tag != 0) — the
  // region where f32 clip math may legitimately differ from double
  function automatic bit c9nced(input int px, input int py);
    real cx, cy;
    cx = px + 0.5; cy = py + 0.5;
    c9nced = 1'b0;
    for (int i = 0; i < c9n; i++) begin
      int  j;
      real ax, ay, bx, by, vx, vy, wx, wy, tt, dx, dy;
      j = (i + 1 == c9n) ? 0 : i + 1;
      if (c9tag[i] != 0 || c9tag[j] != 0) begin
        ax = c9sx(i); ay = c9sy(i); bx = c9sx(j); by = c9sy(j);
        vx = bx - ax; vy = by - ay; wx = cx - ax; wy = cy - ay;
        tt = (vx*vx + vy*vy > 0.0) ? (wx*vx + wy*vy)/(vx*vx + vy*vy)
                                   : 0.0;
        if (tt < 0.0) tt = 0.0;
        if (tt > 1.0) tt = 1.0;
        dx = wx - tt*vx; dy = wy - tt*vy;
        if (dx*dx + dy*dy < 1.0) c9nced = 1'b1;
      end
    end
  endfunction

  // ---- stimulus ------------------------------------------------------------
  apu_rast_draw_t d;
  logic [31:0] ex, got;
  int mism;
  int c2_cyc;

  initial begin
    rd = '0; w_o = '0; w_v = 1'b0;
    // guard machinery unused in this bench — mark the arrays driven
    i_mem.guard_on = 1'b0;
    i_mem.guard_n = 0;
    for (int i = 0; i < i_mem.GUARD_MAX; i++) begin
      i_mem.guard_lo[i] = '0;
      i_mem.guard_hi[i] = '0;
    end
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    // ================= case 1: CLEAR =================
    cases++;
    d = mk_clear();
    // clear_color[0..3] = {r,g,b,a} = {0.25,0.5,0.75,1.0}
    d.clear_color[0] = 32'h3E800000;   // 0.25
    d.clear_color[1] = 32'h3F000000;   // 0.5
    d.clear_color[2] = 32'h3F400000;   // 0.75
    d.clear_color[3] = 32'h3F800000;   // 1.0
    c0 = cyc;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT));
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case1 code=%0d", w_dpl.code));
    ex = 32'hFFBF8040;                 // {a=255,b=191,g=128,r=64}
    for (int y = 0; y < 32; y++)
      for (int x = 0; x < 32; x++) begin
        checks++;
        if (fbpx(x, y) != ex)
          fail($sformatf("case1 px(%0d,%0d)=%08x exp=%08x",
                         x, y, fbpx(x, y), ex));
      end

    // ================= case 2: front triangle =================
    cases++;
    // ndc positions -> screen 16.8 (exact fp32 math):
    //   v0 (-0.875,-0.875) -> (2,2)   red
    //   v1 (0.75,-0.625)   -> (28,6)  green
    //   v2 (-0.625,0.875)  -> (6,30)  blue
    put_vert(0, 32'hBF600000, 32'hBF600000,
                32'h3F800000, 32'h00000000, 32'h00000000, 32'h3F800000);
    put_vert(1, 32'h3F400000, 32'hBF200000,
                32'h00000000, 32'h3F800000, 32'h00000000, 32'h3F800000);
    put_vert(2, 32'hBF200000, 32'h3F600000,
                32'h00000000, 32'h00000000, 32'h3F800000, 32'h3F800000);
    ref_xi = '{512, 7168, 1536}; ref_yi = '{512, 1536, 7680};
    ref_col[0] = '{1.0, 0.0, 0.0, 1.0};
    ref_col[1] = '{0.0, 1.0, 0.0, 1.0};
    ref_col[2] = '{0.0, 0.0, 1.0, 1.0};
    c0 = cyc;
    d = mk_draw();
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_DRAW_EXT));
    c2_cyc = int'(cyc - c0);
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case2 code=%0d", w_dpl.code));

    mism = 0;
    for (int y = 0; y < 32; y++)
      for (int x = 0; x < 32; x++) begin
        logic [31:0] rpx = ref_px(x, y);
        checks++;
        if (rpx == 32'hFFFF_FFFF) begin
          if (fbpx(x, y) != ex)
            fail($sformatf("case2 out px(%0d,%0d)=%08x expclr=%08x",
                           x, y, fbpx(x, y), ex));
        end else begin
          got = fbpx(x, y);
          for (int c = 0; c < 4; c++) begin
            automatic int dv = int'(got[8*c +: 8]) -
                               int'(rpx[8*c +: 8]);
            if (dv < -1 || dv > 1) begin
              mism++;
              if (mism <= 12)
                $display("case2 px(%0d,%0d)=%08x ref=%08x",
                         x, y, got, rpx);
            end
          end
        end
      end
    if (mism != 0)
      fail($sformatf("case2 %0d channel mismatches", mism));

    // ================= case 3: reversed winding ===================
    cases++;
    // same triangle with v1/v2 swapped -> back face, fully culled
    put_vert(1, 32'hBF200000, 32'h3F600000,
                32'h00000000, 32'h00000000, 32'h3F800000, 32'h3F800000);
    put_vert(2, 32'h3F400000, 32'hBF200000,
                32'h00000000, 32'h3F800000, 32'h00000000, 32'h3F800000);
    // fresh clear to a distinct color first
    d = mk_clear();
    d.clear_color[0] = 32'h3DCCCCCD;   // 0.1
    d.clear_color[1] = 32'h3DCCCCCD;
    d.clear_color[2] = 32'h3DCCCCCD;
    d.clear_color[3] = 32'h3F800000;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT));
    ex = {8'hFF, 8'($rtoi(255.0*0.1 + 0.5)),
          8'($rtoi(255.0*0.1 + 0.5)), 8'($rtoi(255.0*0.1 + 0.5))};
    d = mk_draw();
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_DRAW_EXT));
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case3 code=%0d", w_dpl.code));
    for (int y = 0; y < 32; y++)
      for (int x = 0; x < 32; x++) begin
        checks++;
        if (fbpx(x, y) != ex)
          fail($sformatf("case3 px(%0d,%0d)=%08x expclr=%08x (culled)",
                         x, y, fbpx(x, y), ex));
      end

    // ============ case 3b: CCW front (varying-swap path) ============
    cases++;
    // same negative-shoelace geometry, now declared CCW-front: the
    // draw renders and S_PR_AREA swaps geom slots 1/2.  The post-swap
    // order equals case 2's winding, so its reference arrays hold; the
    // varying prefetch must follow the swap (G2c regression guard —
    // pre-swap records paired with post-swap weights exchanged the
    // green/blue contributions in the guest vkcmp oracle).
    d = mk_draw();
    d.front_ccw = 1'b1;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_DRAW_EXT));
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case3b code=%0d", w_dpl.code));
    mism = 0;
    for (int y = 0; y < 32; y++)
      for (int x = 0; x < 32; x++) begin
        logic [31:0] rpx = ref_px(x, y);
        checks++;
        if (rpx == 32'hFFFF_FFFF) begin
          if (fbpx(x, y) != ex)
            fail($sformatf("case3b out px(%0d,%0d)=%08x expclr=%08x",
                           x, y, fbpx(x, y), ex));
        end else begin
          got = fbpx(x, y);
          for (int c = 0; c < 4; c++) begin
            automatic int dv = int'(got[8*c +: 8]) -
                               int'(rpx[8*c +: 8]);
            if (dv < -1 || dv > 1) begin
              mism++;
              if (mism <= 12)
                $display("case3b px(%0d,%0d)=%08x ref=%08x",
                         x, y, got, rpx);
            end
          end
        end
      end
    if (mism != 0)
      fail($sformatf("case3b %0d channel mismatches", mism));

    // ================= case 4: strip quad + scissor ===============
    cases++;
    // uniform-color quad: v0 TL, v1 TR, v2 BL, v3 BR covering
    // pixels 4..27; scissor (8,8,16,16)
    put_vert(0, 32'hBF400000, 32'hBF400000,
                32'h3E4CCCCD, 32'h3F19999A, 32'h3F666666, 32'h3F800000);
    put_vert(1, 32'h3F400000, 32'hBF400000,
                32'h3E4CCCCD, 32'h3F19999A, 32'h3F666666, 32'h3F800000);
    put_vert(2, 32'hBF400000, 32'h3F400000,
                32'h3E4CCCCD, 32'h3F19999A, 32'h3F666666, 32'h3F800000);
    put_vert(3, 32'h3F400000, 32'h3F400000,
                32'h3E4CCCCD, 32'h3F19999A, 32'h3F666666, 32'h3F800000);
    d = mk_clear();
    d.clear_color[0] = 32'h00000000;
    d.clear_color[1] = 32'h00000000;
    d.clear_color[2] = 32'h00000000;
    d.clear_color[3] = 32'h3F800000;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT));
    d = mk_draw();
    d.topology = 8'd4;                 // TRIANGLE_STRIP
    d.vertex_count = 4;
    d.sc_x = 8; d.sc_y = 8; d.sc_w = 16; d.sc_h = 16;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_DRAW_EXT));
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case4 code=%0d", w_dpl.code));
    for (int y = 0; y < 32; y++)
      for (int x = 0; x < 32; x++) begin
        logic insc, inq;
        insc = (x >= 8 && x < 24 && y >= 8 && y < 24);
        inq  = (x >= 4 && x < 28 && y >= 4 && y < 28);
        checks++;
        got = fbpx(x, y);
        if (insc && inq) begin
          // uniform color (0.2,0.6,0.9,1.0) +-1 LSB
          for (int c = 0; c < 4; c++) begin
            automatic int rv =
              c == 0 ? 51 : c == 1 ? 153 : c == 2 ? 230 : 255;
            automatic int dv = int'(got[8*c +: 8]) - rv;
            if (dv < -1 || dv > 1)
              fail($sformatf("case4 px(%0d,%0d)=%08x exp~%08x",
                             x, y, got,
                             {8'd255, 8'd230, 8'd153, 8'd51}));
          end
        end else begin
          if (got != 32'hFF000000)
            fail($sformatf("case4 px(%0d,%0d)=%08x expclr=ff000000",
                           x, y, got));
        end
      end

    // ================= case 5: BGRA8_SRGB flat colour ============
    cases++;
    // fresh clear to opaque black
    d = mk_clear();
    d.clear_color[0] = 32'h00000000;
    d.clear_color[1] = 32'h00000000;
    d.clear_color[2] = 32'h00000000;
    d.clear_color[3] = 32'h3F800000;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT));
    // case-2 triangle, flat linear colour (0.5, 0.25, 0.4, 1.0)
    put_vert(0, 32'hBF600000, 32'hBF600000,
                32'h3F000000, 32'h3E800000, 32'h3ECCCCCD, 32'h3F800000);
    put_vert(1, 32'h3F400000, 32'hBF200000,
                32'h3F000000, 32'h3E800000, 32'h3ECCCCCD, 32'h3F800000);
    put_vert(2, 32'hBF200000, 32'h3F600000,
                32'h3F000000, 32'h3E800000, 32'h3ECCCCCD, 32'h3F800000);
    ref_xi = '{512, 7168, 1536}; ref_yi = '{512, 1536, 7680};
    d = mk_draw();
    d.ca[0].fmt = 8'(APU_IMG_FMT_B8G8R8A8_SRGB);
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_DRAW_EXT));
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case5 code=%0d", w_dpl.code));
    // BGRA byte order: {a, r_srgb, g_srgb, b_srgb}
    ex = {8'hFF,
          APU_SRGB_ENC[f_u12(32'h3F000000)],
          APU_SRGB_ENC[f_u12(32'h3E800000)],
          APU_SRGB_ENC[f_u12(32'h3ECCCCCD)]};
    for (int y = 0; y < 32; y++)
      for (int x = 0; x < 32; x++) begin
        checks++;
        got = fbpx(x, y);
        if (ref_px(x, y) == 32'hFFFF_FFFF) begin
          if (got != 32'hFF000000)
            fail($sformatf("case5 out px(%0d,%0d)=%08x expclr", x, y, got));
        end else if (px_bad(got, ex, 1))
          fail($sformatf("case5 px(%0d,%0d)=%08x exp~%08x",
                         x, y, got, ex));
      end

    // ================= case 6: alpha blend + RGB mask ============
    cases++;
    // clear (0.2,0.2,0.2,0.4) -> bytes {51,51,51,102}
    d = mk_clear();
    d.clear_color[0] = 32'h3E4CCCCD;
    d.clear_color[1] = 32'h3E4CCCCD;
    d.clear_color[2] = 32'h3E4CCCCD;
    d.clear_color[3] = 32'h3EA3D70A;   // 0.32 -> byte 82... set below
    d.clear_color[3] = 32'h3ECCCCCD;   // 0.4  -> byte 102
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT));
    // flat src (1.0, 0.0, 0.0, 0.5); blend src*Sa + dst*(1-Sa),
    // alpha src*1 + dst*0 but writeMask RGB only -> dst alpha kept
    put_vert(0, 32'hBF600000, 32'hBF600000,
                32'h3F800000, 32'h00000000, 32'h00000000, 32'h3F000000);
    put_vert(1, 32'h3F400000, 32'hBF200000,
                32'h3F800000, 32'h00000000, 32'h00000000, 32'h3F000000);
    put_vert(2, 32'hBF200000, 32'h3F600000,
                32'h3F800000, 32'h00000000, 32'h00000000, 32'h3F000000);
    d = mk_draw();
    d.blend[0] = '{en: 1'b1,
                  src_c: APU_RAST_BF_SRC_ALPHA,
                  dst_c: APU_RAST_BF_OM_SRC_ALPHA,
                  op_c:  APU_RAST_BO_ADD,
                  src_a: APU_RAST_BF_ONE,
                  dst_a: APU_RAST_BF_ZERO,
                  op_a:  APU_RAST_BO_ADD,
                  mask:  4'h7,
                  pad:   '0};
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_DRAW_EXT));
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case6 code=%0d", w_dpl.code));
    // inside: r=0.5*1.0+0.2*0.5=0.6->153, g=b=0.1->26, a kept=102
    // RGBA byte order: {a, b, g, r}
    ex = {8'd102, 8'd26, 8'd26, 8'd153};
    for (int y = 0; y < 32; y++)
      for (int x = 0; x < 32; x++) begin
        checks++;
        got = fbpx(x, y);
        if (ref_px(x, y) == 32'hFFFF_FFFF) begin
          if (got != 32'h66333333)
            fail($sformatf("case6 out px(%0d,%0d)=%08x expclr", x, y, got));
        end else if (px_bad(got, ex, 1))
          fail($sformatf("case6 px(%0d,%0d)=%08x exp~%08x",
                         x, y, got, ex));
      end

    // ================= case 7: D32 depth, two tris ===============
    cases++;
    // colour clear to opaque black
    d = mk_clear();
    d.clear_color[0] = 32'h00000000;
    d.clear_color[1] = 32'h00000000;
    d.clear_color[2] = 32'h00000000;
    d.clear_color[3] = 32'h3F800000;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT));
    // depth-only clear to 1.0
    d = '0;
    d.op = APU_RAST_OP_CLEAR;
    d.da = '{base: DB, size: 32'h1000, w: 16'd32, h: 16'd32,
             fmt: 8'(APU_IMG_FMT_D32_SFLOAT), mips: 5'd1,
             layers: 10'd1, layer_bytes: 32'h1000};
    d.da_valid = 1'b1;
    d.clear_color[0] = 32'h3F800000;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT));
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case7 dclear code=%0d", w_dpl.code));
    // far tri: screen (2,2),(29,2),(2,29); colour (1,0,0,a=z=0.5)
    put_vert(0, 32'hBF600000, 32'hBF600000,
                32'h3F800000, 32'h00000000, 32'h00000000, 32'h3F000000);
    put_vert(1, 32'h3F500000, 32'hBF600000,
                32'h3F800000, 32'h00000000, 32'h00000000, 32'h3F000000);
    put_vert(2, 32'hBF600000, 32'h3F500000,
                32'h3F800000, 32'h00000000, 32'h00000000, 32'h3F000000);
    d = mk_draw();
    d.da = '{base: DB, size: 32'h1000, w: 16'd32, h: 16'd32,
             fmt: 8'(APU_IMG_FMT_D32_SFLOAT), mips: 5'd1,
             layers: 10'd1, layer_bytes: 32'h1000};
    d.da_valid = 1'b1;
    d.depth_test = 1'b1; d.depth_write = 1'b1; d.depth_op = 3'd1; // LESS
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_DRAW_EXT));
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case7 far code=%0d", w_dpl.code));
    // near tri: screen (6,6),(24,6),(6,24); colour (0,1,0,a=z=0.2)
    put_vert(0, 32'hBF200000, 32'hBF200000,
                32'h00000000, 32'h3F800000, 32'h00000000, 32'h3E4CCCCD);
    put_vert(1, 32'h3F000000, 32'hBF200000,
                32'h00000000, 32'h3F800000, 32'h00000000, 32'h3E4CCCCD);
    put_vert(2, 32'hBF200000, 32'h3F000000,
                32'h00000000, 32'h3F800000, 32'h00000000, 32'h3E4CCCCD);
    d.vertex_count = 3;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_DRAW_EXT));
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case7 near code=%0d", w_dpl.code));
    // directed samples: (10,10) inside both -> near green; (20,5) far
    // only; (28,28) neither. depth = z word (+-2 ulp on drawn frags).
    begin
      int sx[3] = '{10, 20, 28};
      int sy[3] = '{10, 5, 28};
      logic [31:0] sexp[3] = '{32'h3300FF00, 32'h800000FF,
                              32'hFF000000};
      logic [31:0] sdep[3] = '{32'h3E4CCCCD, 32'h3F000000,
                              32'h3F800000};
      for (int s = 0; s < 3; s++) begin
        checks += 2;
        got = fbpx(sx[s], sy[s]);
        if (px_bad(got, sexp[s], 2))
          fail($sformatf("case7 px(%0d,%0d)=%08x exp~%08x",
                         sx[s], sy[s], got, sexp[s]));
        got = dbpx(sx[s], sy[s]);
        begin
          automatic int dv = int'(got) - int'(sdep[s]);
          if (dv < -2 || dv > 2)
            fail($sformatf("case7 dep(%0d,%0d)=%08x exp~%08x",
                           sx[s], sy[s], got, sdep[s]));
        end
      end
    end

    // ================= case 8: indexed + instance-rate ===========
    cases++;
    // clear to opaque black
    d = mk_clear();
    d.clear_color[0] = 32'h0000000;
    d.clear_color[1] = 32'h00000000;
    d.clear_color[2] = 32'h00000000;
    d.clear_color[3] = 32'h3F800000;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT));
    // vb0: 6 verts stride 8, RG32 pos; 0-1 decoys, 2-5 = the quad
    // ndc -0.75/0.75 -> screen 4/28
    apwr(VB +  0, 32'h00000000); apwr(VB +  4, 32'h00000000);
    apwr(VB +  8, 32'h00000000); apwr(VB + 12, 32'h00000000);
    apwr(VB + 16, 32'hBF400000); apwr(VB + 20, 32'hBF400000); // v2
    apwr(VB + 24, 32'h3F400000); apwr(VB + 28, 32'hBF400000); // v3
    apwr(VB + 32, 32'hBF400000); apwr(VB + 36, 32'h3F400000); // v4
    apwr(VB + 40, 32'h3F400000); apwr(VB + 44, 32'h3F400000); // v5
    // vb1 @ 0x30000: instance-rate colours, stride 16
    apwr(32'h30000 +  0, 32'h3F800000); apwr(32'h30000 +  4, 32'h00000000);
    apwr(32'h30000 +  8, 32'h00000000); apwr(32'h30000 + 12, 32'h3F800000);
    apwr(32'h30000 + 16, 32'h00000000); apwr(32'h30000 + 20, 32'h3F800000);
    apwr(32'h30000 + 24, 32'h00000000); apwr(32'h30000 + 28, 32'h3F800000);
    // ib @ 0x20000: u16 {0,1,2, 2,1,3}
    apwr(32'h20000 + 0, 32'h00010000);
    apwr(32'h20000 + 4, 32'h00020002);
    apwr(32'h20000 + 8, 32'h00030001);
    d = mk_draw();
    d.attr[0].binding = 2'd0; d.attr[0].fmt = APU_RAST_VF_RG32_SFLOAT;
    d.attr[0].offset = 12'd0;
    d.attr[1].binding = 2'd1; d.attr[1].fmt = APU_RAST_VF_RGBA32_SFLOAT;
    d.attr[1].offset = 12'd0;
    d.vb_base[0] = VB;   d.vb_size[0] = 32'h1000; d.vb_stride[0] = 16'd8;
    d.vb_base[1] = 32'h30000; d.vb_size[1] = 32'h1000;
    d.vb_stride[1] = 16'd16;
    d.vb_rate = 4'b0010;                  // binding 1 = instance rate
    d.ib_type = 2'd1;                     // UINT16
    d.ib_base = 32'h20000; d.ib_size = 32'd12;
    d.first_index = 0; d.vertex_offset = 2;
    d.first_instance = 0;
    d.vertex_count = 6; d.instance_count = 2;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_DRAW_INDEXED_EXT));
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case8 code=%0d", w_dpl.code));
    // quad [4,28)x[4,28); instance 1 (green) overwrites instance 0
    for (int y = 0; y < 32; y++)
      for (int x = 0; x < 32; x++) begin
        logic inq;
        inq = (x >= 4 && x < 28 && y >= 4 && y < 28);
        checks++;
        got = fbpx(x, y);
        if (inq) begin
          if (px_bad(got, 32'hFF00FF00, 1))
            fail($sformatf("case8 px(%0d,%0d)=%08x exp~ff00ff00",
                           x, y, got));
        end else if (got != 32'hFF000000)
          fail($sformatf("case8 out px(%0d,%0d)=%08x expclr", x, y, got));
      end

    // ================= case 9: clip space (w<0 + far plane) =======
    cases++;
    // clear to opaque black
    d = mk_clear();
    d.clear_color[0] = 32'h00000000;
    d.clear_color[1] = 32'h00000000;
    d.clear_color[2] = 32'h00000000;
    d.clear_color[3] = 32'h3F800000;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT));
    // clip-space vertices (pos4 layout {x,y,z,w}+{r,g,b,a}, 32 B
    // stride — sh_pos4 makes the stub emit loc0 as Position):
    //   v0 (0, 0, 0.5, 1)       inside
    //   v1 (2, 0.8, 0.25, -0.5) behind the camera: far/eps/guards out
    //   v2 (-0.5, 0.9, 2, 1)    past the far plane (z>w)
    // the far-plane cut emits i01 (ndc 2.0,0.8 -> scr 48,28.8) and
    // i20 (ndc -0.167,0.3 -> scr 13.3,20.8); eps/guard planes then
    // pass — final fan = one tri {i01, i20, v0}.
    apwr(VB +  0, 32'h00000000); apwr(VB +  4, 32'h00000000);
    apwr(VB +  8, 32'h3F000000); apwr(VB + 12, 32'h3F800000);
    apwr(VB + 16, 32'h3F800000); apwr(VB + 20, 32'h00000000);
    apwr(VB + 24, 32'h00000000); apwr(VB + 28, 32'h3F800000);
    apwr(VB + 32, 32'h40000000); apwr(VB + 36, 32'h3F4CCCCD);
    apwr(VB + 40, 32'h3E800000); apwr(VB + 44, 32'hBF000000);
    apwr(VB + 48, 32'h00000000); apwr(VB + 52, 32'h3F800000);
    apwr(VB + 56, 32'h00000000); apwr(VB + 60, 32'h3F800000);
    apwr(VB + 64, 32'hBF000000); apwr(VB + 68, 32'h3F666666);
    apwr(VB + 72, 32'h40000000); apwr(VB + 76, 32'h3F800000);
    apwr(VB + 80, 32'h00000000); apwr(VB + 84, 32'h00000000);
    apwr(VB + 88, 32'h3F800000); apwr(VB + 92, 32'h3F800000);
    sh_pos4 = 1'b1;
    d = mk_draw();
    d.attr[0].fmt = APU_RAST_VF_RGBA32_SFLOAT;
    d.attr[0].offset = 12'd0;
    d.attr[1].fmt = APU_RAST_VF_RGBA32_SFLOAT;
    d.attr[1].offset = 12'd16;
    d.vb_stride[0] = 16'd32;
    clip_arm = 1'b1; clip_fpop = 0;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_DRAW_EXT));
    clip_arm = 1'b0;
    sh_pos4 = 1'b0;
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case9 code=%0d", w_dpl.code));
    // double-precision clip+raster coverage reference
    c9clip('{0.0, 0.0, 0.5, 1.0},
           '{2.0, 0.8, 0.25, -0.5},
           '{-0.5, 0.9, 2.0, 1.0});
    begin
      int nedge = 0, nstr = 0, ngot = 0, nref = 0;
      for (int y = 0; y < 32; y++)
        for (int x = 0; x < 32; x++) begin
          automatic bit rc = c9cov(x, y);
          automatic bit gc = (fbpx(x, y) != 32'hFF000000);
          checks++;
          if (rc) nref++;
          if (gc) ngot++;
          if (gc != rc) begin
            if (c9nced(x, y)) begin
              nedge++;
              if (nedge <= 12)
                $display("case9 clip-edge px(%0d,%0d) got=%0d ref=%0d",
                         x, y, gc, rc);
            end else begin
              nstr++;
              fail($sformatf("case9 strict px(%0d,%0d) got=%0d ref=%0d",
                             x, y, gc, rc));
            end
          end
        end
      checks++;
      if (nedge > 32*32/50)
        fail($sformatf("case9 %0d clip-edge mismatches (>2%%)", nedge));
      $display("RAST_INFO case9 cov_got=%0d cov_ref=%0d clipverts=%0d edge_mism=%0d strict_mism=%0d clip_fpop=%0d",
               ngot, nref, dut.gen_on.cpn_q, nedge, nstr, clip_fpop);
    end

    // ================= case 10: thin tri (partial quads) ==========
    cases++;
    // ~1-px-wide sliver: every covered 2x2 block is partially
    // covered, so helper lanes exist throughout; exact coverage means
    // they never reach the ROP.
    d = mk_clear();
    d.clear_color[0] = 32'h00000000;
    d.clear_color[1] = 32'h00000000;
    d.clear_color[2] = 32'h00000000;
    d.clear_color[3] = 32'h3F800000;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT));
    // screen (8,2) (9.5,2) (8.5,30); flat (0.6,0.2,0.8,1.0)
    put_vert(0, 32'hBF000000, 32'hBF600000,
                32'h3F19999A, 32'h3E4CCCCD, 32'h3F4CCCCD, 32'h3F800000);
    put_vert(1, 32'hBED00000, 32'hBF600000,
                32'h3F19999A, 32'h3E4CCCCD, 32'h3F4CCCCD, 32'h3F800000);
    put_vert(2, 32'hBEF00000, 32'h3F600000,
                32'h3F19999A, 32'h3E4CCCCD, 32'h3F4CCCCD, 32'h3F800000);
    ref_xi = '{2048, 2432, 2176}; ref_yi = '{512, 512, 7680};
    ref_col[0] = '{0.6, 0.2, 0.8, 1.0};
    ref_col[1] = '{0.6, 0.2, 0.8, 1.0};
    ref_col[2] = '{0.6, 0.2, 0.8, 1.0};
    d = mk_draw();
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_DRAW_EXT));
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case10 code=%0d", w_dpl.code));
    begin
      int ncov10 = 0;
      for (int y = 0; y < 32; y++)
        for (int x = 0; x < 32; x++) begin
          checks++;
          got = fbpx(x, y);
          if (ref_px(x, y) == 32'hFFFF_FFFF) begin
            if (got != 32'hFF000000)
              fail($sformatf("case10 helper/out px(%0d,%0d)=%08x expclr",
                             x, y, got));
          end else begin
            ncov10++;
            if (px_bad(got, 32'hFFCC3399, 1))
              fail($sformatf("case10 px(%0d,%0d)=%08x exp~ffcc3399",
                             x, y, got));
          end
        end
      $display("RAST_INFO case10 cov=%0d", ncov10);
    end

    // ================= case 11: full-RGBA alpha blend ============
    cases++;
    // vkcmp blend_layers shape: SRC_ALPHA/ONE_MINUS_SRC_ALPHA on both
    // colour and alpha, ADD, mask 0xF — dst alpha participates in the
    // blend and is overwritten (case 6 kept it via RGB-only mask)
    // clear (0.2,0.2,0.2,0.4) -> bytes {51,51,51,102}
    d = mk_clear();
    d.clear_color[0] = 32'h3E4CCCCD;
    d.clear_color[1] = 32'h3E4CCCCD;
    d.clear_color[2] = 32'h3E4CCCCD;
    d.clear_color[3] = 32'h3ECCCCCD;
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_CLEAR_ATTACHMENTS_EXT));
    // flat src (1.0, 0.0, 0.0, 0.5); a = 0.5*0.5 + 0.4*0.5 = 0.45 -> 115
    put_vert(0, 32'hBF600000, 32'hBF600000,
                32'h3F800000, 32'h00000000, 32'h00000000, 32'h3F000000);
    put_vert(1, 32'h3F400000, 32'hBF200000,
                32'h3F800000, 32'h00000000, 32'h00000000, 32'h3F000000);
    put_vert(2, 32'hBF200000, 32'h3F600000,
                32'h3F800000, 32'h00000000, 32'h00000000, 32'h3F000000);
    // same screen-space triangle as case 6 — ref_xi/ref_yi still hold
    // case 10's sliver without this
    ref_xi = '{512, 7168, 1536}; ref_yi = '{512, 1536, 7680};
    d = mk_draw();
    d.blend[0] = '{en: 1'b1,
                  src_c: APU_RAST_BF_SRC_ALPHA,
                  dst_c: APU_RAST_BF_OM_SRC_ALPHA,
                  op_c:  APU_RAST_BO_ADD,
                  src_a: APU_RAST_BF_SRC_ALPHA,
                  dst_a: APU_RAST_BF_OM_SRC_ALPHA,
                  op_a:  APU_RAST_BO_ADD,
                  mask:  4'hF,
                  pad:   '0};
    do_work(d, 32'(APU_VN_TYPE_VK_CMD_DRAW_EXT));
    if (w_dpl.code != APU_SH_DONE_OK)
      fail($sformatf("case11 code=%0d", w_dpl.code));
    // inside: r=0.6->153, g=b=0.1->26, a=0.45->~115 (RGBA {a,b,g,r})
    ex = {8'd115, 8'd26, 8'd26, 8'd153};
    for (int y = 0; y < 32; y++)
      for (int x = 0; x < 32; x++) begin
        checks++;
        got = fbpx(x, y);
        if (ref_px(x, y) == 32'hFFFF_FFFF) begin
          if (got != 32'h66333333)
            fail($sformatf("case11 out px(%0d,%0d)=%08x expclr", x, y, got));
        end else if (px_bad(got, ex, 2))
          fail($sformatf("case11 px(%0d,%0d)=%08x exp~%08x",
                         x, y, got, ex));
      end

    // ---- report ---------------------------------------------------------
    if (fails == 0)
      $display("PASS tb_g6lc_apu_rast cases=%0d checks=%0d cycles=%0d",
               cases, checks, cyc);
    else
      $display("FAIL tb_g6lc_apu_rast cases=%0d checks=%0d fails=%0d",
               cases, checks, fails);
    $display("RAST_INFO case2_cycles=%0d", c2_cyc);
    $finish;
  end

  // watchdog
  initial begin
    #2000000000;
    $display("FAIL watchdog timeout");
    $finish;
  end
endmodule
