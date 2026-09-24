// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_obj;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_fet_t fet;
  apu_vgpu_drd_t drd;
  apu_vgpu_qdr_t qdr;
  apu_vgpu_vwx_t vwx;
  apu_vgpu_cxr_t cxr;
  apu_vgpu_cwr_t cwr;
  apu_vgpu_fbr_t fbr;
  apu_vgpu_vbf_t vbf;
  apu_vgpu_iwr_t iwr;
  apu_vgpu_svr_t svr;
  apu_vgpu_ssr_t ssr;
  apu_vgpu_ver_t ver;
  apu_vgpu_fsr_t fsr;
  apu_vgpu_vsr_t vsr;
  apu_vgpu_rzr_t rzr;
  apu_vgpu_dbr_t dbr;
  apu_vgpu_bbr_t bbr;
  apu_vgpu_rcr_t rcr;
  apu_vgpu_dcr_t dcr;
  apu_vgpu_blr_t blr;
  apu_vgpu_scr_t scr;
  apu_vgpu_svc_t svc;
  apu_vgpu_vec_t vec_pin;
  apu_vgpu_fsc_t fsc_pin;
  apu_vgpu_vsc_t vsc_pin;

  logic fsc_req = 0, fsc_rdy, fsc_cpl_v, fsc_cpl_r = 0;
  apu_vgpu_fsc_cpl_t fsc_cpl;
  apu_vgpu_fsc_t fsc;
  logic fsc_rd_v, fsc_rd_rdy, fsc_rsp_v = 0, fsc_rsp_rdy, fsc_rsp_ok = 0;
  logic [63:0] fsc_rd_addr, fsc_rsp_addr = 0, fsc_seen0 = 0, fsc_seen1 = 0;
  logic [31:0] fsc_rd_len, fsc_rsp_len = 0;
  logic [255:0] fsc_rsp_data = 0;
  logic fsc_fail = 0, fsc_bad_hdr = 0, fsc_bad_handle = 0, fsc_bad_stage = 0;
  logic fsc_bad_offlen = 0, fsc_bad_tokens = 0, fsc_bad_so = 0, fsc_bad_text0 = 0;
  logic fsc_order = 0;
  int fsc_nread = 0, fsc_base = 0;

  logic fce_req = 0, fce_rdy, fce_cpl_v, fce_cpl_r = 0;
  apu_vgpu_fce_cpl_t fce_cpl;
  apu_vgpu_fce_t fce;

  logic vsc_req = 0, vsc_rdy, vsc_cpl_v, vsc_cpl_r = 0;
  apu_vgpu_vsc_cpl_t vsc_cpl;
  apu_vgpu_vsc_t vsc;
  logic vsc_rd_v, vsc_rd_rdy, vsc_rsp_v = 0, vsc_rsp_rdy, vsc_rsp_ok = 0;
  logic [63:0] vsc_rd_addr, vsc_rsp_addr = 0, vsc_seen0 = 0, vsc_seen1 = 0;
  logic [31:0] vsc_rd_len, vsc_rsp_len = 0;
  logic [255:0] vsc_rsp_data = 0;
  logic vsc_fail = 0, vsc_bad_hdr = 0, vsc_bad_handle = 0, vsc_bad_stage = 0;
  logic vsc_bad_offlen = 0, vsc_bad_tokens = 0, vsc_bad_so = 0, vsc_bad_text0 = 0;
  logic vsc_order = 0;
  int vsc_nread = 0, vsc_base = 0;

  logic vse_req = 0, vse_rdy, vse_cpl_v, vse_cpl_r = 0;
  apu_vgpu_vse_cpl_t vse_cpl;
  apu_vgpu_vse_t vse;

  logic sfc_req = 0, sfc_rdy, sfc_cpl_v, sfc_cpl_r = 0;
  apu_vgpu_sfc_cpl_t sfc_cpl;
  apu_vgpu_sfc_t sfc;
  logic sfc_rd_v, sfc_rd_rdy, sfc_rsp_v = 0, sfc_rsp_rdy, sfc_rsp_ok = 0;
  logic [63:0] sfc_rd_addr, sfc_rsp_addr = 0, sfc_seen = 0;
  logic [31:0] sfc_rd_len, sfc_rsp_len = 0;
  logic [255:0] sfc_rsp_data = 0;
  logic sfc_fail = 0, sfc_bad_hdr = 0, sfc_bad_handle = 0, sfc_bad_res = 0;
  logic sfc_bad_fmt = 0, sfc_bad_z0 = 0, sfc_bad_z1 = 0, sfc_order = 0;
  int sfc_nread = 0, sfc_base = 0;

  logic sfe_req = 0, sfe_rdy, sfe_cpl_v, sfe_cpl_r = 0;
  apu_vgpu_sfe_cpl_t sfe_cpl, off_cpl;
  apu_vgpu_sfe_t sfe, off_sfe;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] Frag = 32'(APU_VIRGL_SHADER_FRAGMENT);
  localparam logic [31:0] Vstage = 32'(APU_VIRGL_SHADER_VERTEX);
  localparam logic [31:0] VS_T1 = 32'h4c43440a;
  localparam logic [31:0] VS_T2 = 32'h5b4e4920;
  localparam logic [31:0] VS_T3 = 32'h440a5d30;
  localparam logic [31:0] VS_T28 = 32'h200a5d31;
  localparam logic [31:0] VS_T29 = 32'h203a3220;
  localparam logic [31:0] VS_T30 = 32'h0a444e45;
  localparam logic [31:0] FS_T1 = 32'h4c43440a;
  localparam logic [31:0] FS_T2 = 32'h5b4e4920;
  localparam logic [31:0] FS_T3 = 32'h202c5d30;
  localparam logic [31:0] FS_T4 = 32'h454e4547;
  localparam logic [31:0] FS_T5 = 32'h5b434952;

  assign fsc_rd_rdy = fsc_rd_v && rst_ni && !fsc_rsp_v;
  assign vsc_rd_rdy = vsc_rd_v && rst_ni && !vsc_rsp_v;
  assign sfc_rd_rdy = sfc_rd_v && rst_ni && !sfc_rsp_v;

  g6lc_apu_vgpu_fsc #(.Enable(1'b1)) i_fsc (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .cxr_i(cxr), .cwr_i(cwr), .fbr_i(fbr), .vbf_i(vbf), .iwr_i(iwr),
    .svr_i(svr), .ssr_i(ssr), .ver_i(ver), .fsr_i(fsr), .vsr_i(vsr), .rzr_i(rzr),
    .dbr_i(dbr), .bbr_i(bbr), .rcr_i(rcr), .dcr_i(dcr), .blr_i(blr), .scr_i(scr),
    .svc_i(svc), .vec_i(vec_pin),
    .req_valid_i(fsc_req), .req_ready_o(fsc_rdy),
    .cpl_valid_o(fsc_cpl_v), .cpl_ready_i(fsc_cpl_r), .cpl_o(fsc_cpl), .fsc_o(fsc),
    .rd_valid_o(fsc_rd_v), .rd_ready_i(fsc_rd_rdy), .rd_addr_o(fsc_rd_addr),
    .rd_len_o(fsc_rd_len), .rd_rsp_valid_i(fsc_rsp_v), .rd_rsp_ready_o(fsc_rsp_rdy),
    .rd_rsp_ok_i(fsc_rsp_ok), .rd_rsp_addr_i(fsc_rsp_addr), .rd_rsp_len_i(fsc_rsp_len),
    .rd_rsp_data_i(fsc_rsp_data)
  );
  g6lc_apu_vgpu_fce #(.Enable(1'b1)) i_fce (
    .clk_i(clk), .rst_ni, .fsc_i(fsc), .vec_i(vec_pin), .iwr_i(iwr), .fet_i(fet),
    .qdr_i(qdr), .req_valid_i(fce_req), .req_ready_o(fce_rdy),
    .cpl_valid_o(fce_cpl_v), .cpl_ready_i(fce_cpl_r), .cpl_o(fce_cpl), .fce_o(fce)
  );
  g6lc_apu_vgpu_vsc #(.Enable(1'b1)) i_vsc (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .cxr_i(cxr), .cwr_i(cwr), .fbr_i(fbr), .vbf_i(vbf), .iwr_i(iwr),
    .svr_i(svr), .ssr_i(ssr), .ver_i(ver), .fsr_i(fsr), .vsr_i(vsr), .rzr_i(rzr),
    .dbr_i(dbr), .bbr_i(bbr), .rcr_i(rcr), .dcr_i(dcr), .blr_i(blr), .scr_i(scr),
    .svc_i(svc), .vec_i(vec_pin), .fsc_i(fsc_pin),
    .req_valid_i(vsc_req), .req_ready_o(vsc_rdy),
    .cpl_valid_o(vsc_cpl_v), .cpl_ready_i(vsc_cpl_r), .cpl_o(vsc_cpl), .vsc_o(vsc),
    .rd_valid_o(vsc_rd_v), .rd_ready_i(vsc_rd_rdy), .rd_addr_o(vsc_rd_addr),
    .rd_len_o(vsc_rd_len), .rd_rsp_valid_i(vsc_rsp_v), .rd_rsp_ready_o(vsc_rsp_rdy),
    .rd_rsp_ok_i(vsc_rsp_ok), .rd_rsp_addr_i(vsc_rsp_addr), .rd_rsp_len_i(vsc_rsp_len),
    .rd_rsp_data_i(vsc_rsp_data)
  );
  g6lc_apu_vgpu_vse #(.Enable(1'b1)) i_vse (
    .clk_i(clk), .rst_ni, .vsc_i(vsc), .fsc_i(fsc_pin), .iwr_i(iwr), .fet_i(fet),
    .qdr_i(qdr), .req_valid_i(vse_req), .req_ready_o(vse_rdy),
    .cpl_valid_o(vse_cpl_v), .cpl_ready_i(vse_cpl_r), .cpl_o(vse_cpl), .vse_o(vse)
  );
  g6lc_apu_vgpu_sfc #(.Enable(1'b1)) i_sfc (
    .clk_i(clk), .rst_ni, .fet_i(fet), .drd_i(drd), .qdr_i(qdr), .vwx_i(vwx),
    .cxr_i(cxr), .cwr_i(cwr), .fbr_i(fbr), .vbf_i(vbf), .iwr_i(iwr),
    .svr_i(svr), .ssr_i(ssr), .ver_i(ver), .fsr_i(fsr), .vsr_i(vsr), .rzr_i(rzr),
    .dbr_i(dbr), .bbr_i(bbr), .rcr_i(rcr), .dcr_i(dcr), .blr_i(blr), .scr_i(scr),
    .svc_i(svc), .vec_i(vec_pin), .fsc_i(fsc_pin), .vsc_i(vsc_pin),
    .req_valid_i(sfc_req), .req_ready_o(sfc_rdy),
    .cpl_valid_o(sfc_cpl_v), .cpl_ready_i(sfc_cpl_r), .cpl_o(sfc_cpl), .sfc_o(sfc),
    .rd_valid_o(sfc_rd_v), .rd_ready_i(sfc_rd_rdy), .rd_addr_o(sfc_rd_addr),
    .rd_len_o(sfc_rd_len), .rd_rsp_valid_i(sfc_rsp_v), .rd_rsp_ready_o(sfc_rsp_rdy),
    .rd_rsp_ok_i(sfc_rsp_ok), .rd_rsp_addr_i(sfc_rsp_addr), .rd_rsp_len_i(sfc_rsp_len),
    .rd_rsp_data_i(sfc_rsp_data)
  );
  g6lc_apu_vgpu_sfe #(.Enable(1'b1)) i_sfe (
    .clk_i(clk), .rst_ni, .sfc_i(sfc), .vsc_i(vsc_pin), .iwr_i(iwr), .fet_i(fet),
    .qdr_i(qdr), .req_valid_i(sfe_req), .req_ready_o(sfe_rdy),
    .cpl_valid_o(sfe_cpl_v), .cpl_ready_i(sfe_cpl_r), .cpl_o(sfe_cpl), .sfe_o(sfe)
  );
  g6lc_apu_vgpu_sfe_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .sfc_i(sfc), .vsc_i(vsc_pin), .iwr_i(iwr), .fet_i(fet),
    .qdr_i(qdr), .req_valid_i(sfe_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(sfe_cpl_r), .cpl_o(off_cpl), .sfe_o(off_sfe)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu obj timeout case=%0d", cases); end

  function automatic logic [255:0] fsc_beat(input int idx);
    fsc_beat = '0;
    if (idx == 0) begin
      fsc_beat[31:0] = VS_T28;
      fsc_beat[63:32] = VS_T29;
      fsc_beat[95:64] = VS_T30;
      fsc_beat[159:128] = fsc_bad_hdr ? 32'h0 : APU_VIRGL_FS_HDR;
      fsc_beat[191:160] = fsc_bad_handle ? APU_VIRGL_VS_HANDLE : APU_VIRGL_FS_HANDLE;
      fsc_beat[223:192] = fsc_bad_stage ? Vstage : Frag;
      fsc_beat[255:224] = fsc_bad_offlen ? 32'h0 : APU_VIRGL_FS_OFFLEN;
    end else begin
      fsc_beat[31:0] = fsc_bad_tokens ? 32'h0 : APU_VIRGL_FS_TOKENS;
      fsc_beat[63:32] = fsc_bad_so ? 32'd1 : 32'h0;
      fsc_beat[95:64] = fsc_bad_text0 ? APU_VIRGL_VS_TEXT0 : APU_VIRGL_FS_TEXT0;
      fsc_beat[127:96] = FS_T1;
      fsc_beat[159:128] = FS_T2;
      fsc_beat[191:160] = FS_T3;
      fsc_beat[223:192] = FS_T4;
      fsc_beat[255:224] = FS_T5;
    end
  endfunction

  function automatic logic [255:0] vsc_beat(input int idx);
    vsc_beat = '0;
    if (idx == 0) begin
      vsc_beat[31:0] = APU_VIRGL_SF_HDR;
      vsc_beat[63:32] = APU_VIRGL_SURFACE_HANDLE;
      vsc_beat[95:64] = APU_VIRGL_RES_RT;
      vsc_beat[127:96] = APU_VIRGL_FMT_B8G8R8X8;
      vsc_beat[223:192] = vsc_bad_hdr ? 32'h0 : APU_VIRGL_VS_HDR;
      vsc_beat[255:224] = vsc_bad_handle ? APU_VIRGL_FS_HANDLE : APU_VIRGL_VS_HANDLE;
    end else begin
      vsc_beat[31:0] = vsc_bad_stage ? Frag : Vstage;
      vsc_beat[63:32] = vsc_bad_offlen ? 32'h0 : APU_VIRGL_VS_OFFLEN;
      vsc_beat[95:64] = vsc_bad_tokens ? 32'h0 : APU_VIRGL_VS_TOKENS;
      vsc_beat[127:96] = vsc_bad_so ? 32'd1 : 32'h0;
      vsc_beat[159:128] = vsc_bad_text0 ? APU_VIRGL_FS_TEXT0 : APU_VIRGL_VS_TEXT0;
      vsc_beat[191:160] = VS_T1;
      vsc_beat[223:192] = VS_T2;
      vsc_beat[255:224] = VS_T3;
    end
  endfunction

  function automatic logic [255:0] sfc_beat();
    sfc_beat = '0;
    sfc_beat[31:0] = sfc_bad_hdr ? 32'h0 : APU_VIRGL_SF_HDR;
    sfc_beat[63:32] = sfc_bad_handle ? APU_VIRGL_VS_HANDLE : APU_VIRGL_SURFACE_HANDLE;
    sfc_beat[95:64] = sfc_bad_res ? APU_VIRGL_RES_SCAN : APU_VIRGL_RES_RT;
    sfc_beat[127:96] = sfc_bad_fmt ? 32'h0 : APU_VIRGL_FMT_B8G8R8X8;
    sfc_beat[159:128] = sfc_bad_z0 ? 32'd1 : 32'h0;
    sfc_beat[191:160] = sfc_bad_z1 ? 32'd1 : 32'h0;
    sfc_beat[223:192] = APU_VIRGL_VS_HDR;
    sfc_beat[255:224] = APU_VIRGL_VS_HANDLE;
  endfunction

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      fsc_rsp_v <= 1'b0;
      fsc_nread <= 0;
      fsc_order <= 1'b0;
    end else if (fsc_rsp_v && fsc_rsp_rdy) fsc_rsp_v <= 1'b0;
    else if (fsc_rd_v && fsc_rd_rdy) begin
      int idx;
      logic [63:0] want;
      idx = fsc_nread - fsc_base;
      want = idx == 0 ? APU_VGPU_FSC_ADDR : APU_VGPU_FSC_LAST;
      if (fsc_rd_addr != want) fsc_order <= 1'b1;
      if (idx == 0) fsc_seen0 <= fsc_rd_addr;
      fsc_seen1 <= fsc_rd_addr;
      fsc_rsp_addr <= fsc_rd_addr;
      fsc_rsp_len <= fsc_rd_len;
      fsc_rsp_data <= fsc_beat(idx);
      fsc_rsp_ok <= !fsc_fail;
      fsc_fail <= 1'b0;
      if (idx == 0) begin
        fsc_bad_hdr <= 1'b0;
        fsc_bad_handle <= 1'b0;
        fsc_bad_stage <= 1'b0;
        fsc_bad_offlen <= 1'b0;
      end
      if (idx == 1) begin
        fsc_bad_tokens <= 1'b0;
        fsc_bad_so <= 1'b0;
        fsc_bad_text0 <= 1'b0;
      end
      fsc_nread <= fsc_nread + 1;
      fsc_rsp_v <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      vsc_rsp_v <= 1'b0;
      vsc_nread <= 0;
      vsc_order <= 1'b0;
    end else if (vsc_rsp_v && vsc_rsp_rdy) vsc_rsp_v <= 1'b0;
    else if (vsc_rd_v && vsc_rd_rdy) begin
      int idx;
      logic [63:0] want;
      idx = vsc_nread - vsc_base;
      want = idx == 0 ? APU_VGPU_VSC_ADDR : APU_VGPU_VSC_LAST;
      if (vsc_rd_addr != want) vsc_order <= 1'b1;
      if (idx == 0) vsc_seen0 <= vsc_rd_addr;
      vsc_seen1 <= vsc_rd_addr;
      vsc_rsp_addr <= vsc_rd_addr;
      vsc_rsp_len <= vsc_rd_len;
      vsc_rsp_data <= vsc_beat(idx);
      vsc_rsp_ok <= !vsc_fail;
      vsc_fail <= 1'b0;
      if (idx == 0) begin
        vsc_bad_hdr <= 1'b0;
        vsc_bad_handle <= 1'b0;
      end
      if (idx == 1) begin
        vsc_bad_stage <= 1'b0;
        vsc_bad_offlen <= 1'b0;
        vsc_bad_tokens <= 1'b0;
        vsc_bad_so <= 1'b0;
        vsc_bad_text0 <= 1'b0;
      end
      vsc_nread <= vsc_nread + 1;
      vsc_rsp_v <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      sfc_rsp_v <= 1'b0;
      sfc_nread <= 0;
      sfc_order <= 1'b0;
    end else if (sfc_rsp_v && sfc_rsp_rdy) sfc_rsp_v <= 1'b0;
    else if (sfc_rd_v && sfc_rd_rdy) begin
      if (sfc_rd_addr != APU_VGPU_SFC_ADDR) sfc_order <= 1'b1;
      sfc_seen <= sfc_rd_addr;
      sfc_rsp_addr <= sfc_rd_addr;
      sfc_rsp_len <= sfc_rd_len;
      sfc_rsp_data <= sfc_beat();
      sfc_rsp_ok <= !sfc_fail;
      sfc_fail <= 1'b0;
      sfc_bad_hdr <= 1'b0;
      sfc_bad_handle <= 1'b0;
      sfc_bad_res <= 1'b0;
      sfc_bad_fmt <= 1'b0;
      sfc_bad_z0 <= 1'b0;
      sfc_bad_z1 <= 1'b0;
      sfc_nread <= sfc_nread + 1;
      sfc_rsp_v <= 1'b1;
    end
  end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic scene_in;
    fet = '0;
    fet.valid = 1'b1;
    fet.kind = VGPU_CMD_SUBMIT_3D;
    fet.cmd0 = Cmd0;
    fet.beats = APU_VGPU_EXEC_BEATS;
    drd = '0;
    drd.valid = 1'b1;
    drd.count = APU_VIRGL_VERT_COUNT;
    drd.prim = APU_VIRGL_PRIM_STRIP;
    qdr = '0;
    qdr.valid = 1'b1;
    qdr.x0 = APU_VIRGL_F32_NEG_ONE;
    qdr.last = APU_VIRGL_F32_ONE;
    vwx = '0;
    vwx.valid = 1'b1;
    vwx.x_neg = 16'd0;
    vwx.y_neg = 16'd0;
    vwx.x_pos = 16'd640;
    vwx.y_pos = 16'd480;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    cwr = '0;
    cwr.valid = 1'b1;
    cwr.word = APU_VGPU_CLEAR_WORD;
    fbr = '0;
    fbr.valid = 1'b1;
    fbr.surface = APU_VIRGL_SURFACE_HANDLE;
    fbr.word = APU_VGPU_CLEAR_WORD;
    vbf = '0;
    vbf.valid = 1'b1;
    vbf.stride = APU_VIRGL_VERT_STRIDE;
    vbf.offset = 32'h0;
    vbf.resource = APU_VIRGL_RES_VBO;
    iwr = '0;
    iwr.valid = 1'b1;
    iwr.resource = APU_VIRGL_RES_VBO;
    iwr.nbytes = APU_VIRGL_VBO_BYTES;
    svr = '0;
    svr.valid = 1'b1;
    svr.stage = Frag;
    svr.slot = 32'h0;
    svr.handle = APU_VIRGL_SV_HANDLE;
    ssr = '0;
    ssr.valid = 1'b1;
    ssr.stage = Frag;
    ssr.slot = 32'h0;
    ssr.handle = APU_VIRGL_SS_HANDLE;
    ver = '0;
    ver.valid = 1'b1;
    ver.hdr = APU_VIRGL_VEB_HDR;
    ver.handle = APU_VIRGL_VE_HANDLE;
    fsr = '0;
    fsr.valid = 1'b1;
    fsr.handle = APU_VIRGL_FS_HANDLE;
    fsr.stage = Frag;
    vsr = '0;
    vsr.valid = 1'b1;
    vsr.handle = APU_VIRGL_VS_HANDLE;
    vsr.stage = Vstage;
    rzr = '0;
    rzr.valid = 1'b1;
    rzr.hdr = APU_VIRGL_RB_HDR;
    rzr.handle = APU_VIRGL_RZ_HANDLE;
    dbr = '0;
    dbr.valid = 1'b1;
    dbr.hdr = APU_VIRGL_DB_HDR;
    dbr.handle = APU_VIRGL_DS_HANDLE;
    bbr = '0;
    bbr.valid = 1'b1;
    bbr.hdr = APU_VIRGL_BB_HDR;
    bbr.handle = APU_VIRGL_BL_HANDLE;
    rcr = '0;
    rcr.valid = 1'b1;
    rcr.hdr = APU_VIRGL_RZ_HDR;
    rcr.handle = APU_VIRGL_RZ_HANDLE;
    dcr = '0;
    dcr.valid = 1'b1;
    dcr.hdr = APU_VIRGL_DS_HDR;
    dcr.handle = APU_VIRGL_DS_HANDLE;
    blr = '0;
    blr.valid = 1'b1;
    blr.hdr = APU_VIRGL_BL_HDR;
    blr.handle = APU_VIRGL_BL_HANDLE;
    blr.s2 = APU_VIRGL_BLEND_S2;
    scr = '0;
    scr.valid = 1'b1;
    scr.hdr = APU_VIRGL_SS_HDR;
    scr.handle = APU_VIRGL_SS_HANDLE;
    scr.s0 = APU_VIRGL_SSTATE_S0;
    scr.max_lod = APU_VIRGL_SSTATE_MAX_LOD;
    svc = '0;
    svc.valid = 1'b1;
    svc.hdr = APU_VIRGL_SV_HDR;
    svc.handle = APU_VIRGL_SV_HANDLE;
    svc.resource = APU_VIRGL_RES_SCAN;
    svc.format = APU_VIRGL_SV_FMT;
    svc.swizzle = APU_VIRGL_SWIZZLE_IDENTITY;
  endtask

  task automatic vec_in;
    vec_pin = '0;
    vec_pin.valid = 1'b1;
    vec_pin.hdr = APU_VIRGL_VE_HDR;
    vec_pin.handle = APU_VIRGL_VE_HANDLE;
    vec_pin.off0 = 32'h0;
    vec_pin.fmt0 = APU_VIRGL_FMT_R32G32B32A32_FLOAT;
    vec_pin.off1 = 32'd16;
    vec_pin.fmt1 = APU_VIRGL_FMT_R32G32_FLOAT;
  endtask

  task automatic fsc_in;
    fsc_pin = '0;
    fsc_pin.valid = 1'b1;
    fsc_pin.hdr = APU_VIRGL_FS_HDR;
    fsc_pin.handle = APU_VIRGL_FS_HANDLE;
    fsc_pin.stage = Frag;
    fsc_pin.offlen = APU_VIRGL_FS_OFFLEN;
    fsc_pin.tokens = APU_VIRGL_FS_TOKENS;
    fsc_pin.text0 = APU_VIRGL_FS_TEXT0;
  endtask

  task automatic vsc_in;
    vsc_pin = '0;
    vsc_pin.valid = 1'b1;
    vsc_pin.hdr = APU_VIRGL_VS_HDR;
    vsc_pin.handle = APU_VIRGL_VS_HANDLE;
    vsc_pin.stage = Vstage;
    vsc_pin.offlen = APU_VIRGL_VS_OFFLEN;
    vsc_pin.tokens = APU_VIRGL_VS_TOKENS;
    vsc_pin.text0 = APU_VIRGL_VS_TEXT0;
  endtask

  function automatic logic fsc_ok(input apu_vgpu_fsc_t rec);
    fsc_ok = rec.valid && rec.hdr == APU_VIRGL_FS_HDR &&
             rec.handle == APU_VIRGL_FS_HANDLE && rec.stage == Frag &&
             rec.offlen == APU_VIRGL_FS_OFFLEN && rec.tokens == APU_VIRGL_FS_TOKENS &&
             rec.text0 == APU_VIRGL_FS_TEXT0 && rec.handle != APU_VIRGL_VS_HANDLE &&
             rec.text0 != APU_VIRGL_VS_TEXT0;
  endfunction

  function automatic logic vsc_ok(input apu_vgpu_vsc_t rec);
    vsc_ok = rec.valid && rec.hdr == APU_VIRGL_VS_HDR &&
             rec.handle == APU_VIRGL_VS_HANDLE && rec.stage == Vstage &&
             rec.offlen == APU_VIRGL_VS_OFFLEN && rec.tokens == APU_VIRGL_VS_TOKENS &&
             rec.text0 == APU_VIRGL_VS_TEXT0 && rec.handle != APU_VIRGL_FS_HANDLE &&
             rec.text0 != APU_VIRGL_FS_TEXT0;
  endfunction

  function automatic logic sfc_ok(input apu_vgpu_sfc_t rec);
    sfc_ok = rec.valid && rec.hdr == APU_VIRGL_SF_HDR &&
             rec.handle == APU_VIRGL_SURFACE_HANDLE && rec.resource == APU_VIRGL_RES_RT &&
             rec.format == APU_VIRGL_FMT_B8G8R8X8 && rec.hdr != rec.handle &&
             rec.handle != APU_VIRGL_VS_HANDLE;
  endfunction

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_sfe == '0 &&
          off_cpl == '0);
  endtask

  task automatic fsc_step(input apu_vgpu_fsc_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!fsc_rdy) @(negedge clk);
    cases++;
    n0 = fsc_nread;
    fsc_base = fsc_nread;
    fsc_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    fsc_req = 1'b0;
    while (!fsc_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), fsc_cpl.status == st);
    quiet();
    if (st == APU_VGPU_FSC_OK) begin
      check("fragment shader", fsc_ok(fsc));
      check("fragment read", fsc_nread == n0 + 2 && !fsc_order &&
            fsc_seen0 == APU_VGPU_FSC_ADDR && fsc_seen1 == APU_VGPU_FSC_LAST);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad handle" ||
                 name == "bad stage" || name == "bad offlen") begin
      check("one beat", fsc_nread == n0 + 1 && !fsc.valid);
    end else if (name == "bad tokens" || name == "bad so" || name == "bad text0") begin
      check("two beats", fsc_nread == n0 + 2 && !fsc.valid);
    end else check("no read", fsc_nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), fsc_cpl_v);
    fsc_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    fsc_cpl_r = 1'b0;
    while (fsc_cpl_v) @(negedge clk);
  endtask

  task automatic fce_step(input apu_vgpu_fce_status_e st, input string name);
    @(negedge clk);
    while (!fce_rdy) @(negedge clk);
    cases++;
    fce_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    fce_req = 1'b0;
    while (!fce_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), fce_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), fce_cpl_v);
    fce_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    fce_cpl_r = 1'b0;
    while (fce_cpl_v) @(negedge clk);
  endtask

  task automatic vsc_step(input apu_vgpu_vsc_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!vsc_rdy) @(negedge clk);
    cases++;
    n0 = vsc_nread;
    vsc_base = vsc_nread;
    vsc_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vsc_req = 1'b0;
    while (!vsc_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vsc_cpl.status == st);
    quiet();
    if (st == APU_VGPU_VSC_OK) begin
      check("vertex shader", vsc_ok(vsc));
      check("vertex read", vsc_nread == n0 + 2 && !vsc_order &&
            vsc_seen0 == APU_VGPU_VSC_ADDR && vsc_seen1 == APU_VGPU_VSC_LAST);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad handle") begin
      check("one beat", vsc_nread == n0 + 1 && !vsc.valid);
    end else if (name == "bad stage" || name == "bad offlen" || name == "bad tokens" ||
                 name == "bad so" || name == "bad text0") begin
      check("two beats", vsc_nread == n0 + 2 && !vsc.valid);
    end else check("no read", vsc_nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), vsc_cpl_v);
    vsc_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vsc_cpl_r = 1'b0;
    while (vsc_cpl_v) @(negedge clk);
  endtask

  task automatic vse_step(input apu_vgpu_vse_status_e st, input string name);
    @(negedge clk);
    while (!vse_rdy) @(negedge clk);
    cases++;
    vse_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vse_req = 1'b0;
    while (!vse_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), vse_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), vse_cpl_v);
    vse_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    vse_cpl_r = 1'b0;
    while (vse_cpl_v) @(negedge clk);
  endtask

  task automatic sfc_step(input apu_vgpu_sfc_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!sfc_rdy) @(negedge clk);
    cases++;
    n0 = sfc_nread;
    sfc_base = sfc_nread;
    sfc_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sfc_req = 1'b0;
    while (!sfc_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sfc_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SFC_OK) begin
      check("surface", sfc_ok(sfc));
      check("surface read", sfc_nread == n0 + 1 && !sfc_order &&
            sfc_seen == APU_VGPU_SFC_ADDR);
    end else if (name == "bad beat" || name == "bad hdr" || name == "bad handle" ||
                 name == "bad resource" || name == "bad format" ||
                 name == "bad zero" || name == "bad zero2") begin
      check("one beat", sfc_nread == n0 + 1 && !sfc.valid);
    end else check("no read", sfc_nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), sfc_cpl_v);
    sfc_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sfc_cpl_r = 1'b0;
    while (sfc_cpl_v) @(negedge clk);
  endtask

  task automatic sfe_step(input apu_vgpu_sfe_status_e st, input string name);
    @(negedge clk);
    while (!sfe_rdy) @(negedge clk);
    cases++;
    sfe_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sfe_req = 1'b0;
    while (!sfe_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sfe_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), sfe_cpl_v);
    sfe_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sfe_cpl_r = 1'b0;
    while (sfe_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    fsc_req = 1'b0;
    fce_req = 1'b0;
    vsc_req = 1'b0;
    vse_req = 1'b0;
    sfc_req = 1'b0;
    sfe_req = 1'b0;
    fsc_cpl_r = 1'b0;
    fce_cpl_r = 1'b0;
    vsc_cpl_r = 1'b0;
    vse_cpl_r = 1'b0;
    sfc_cpl_r = 1'b0;
    sfe_cpl_r = 1'b0;
    fsc_rsp_v = 1'b0;
    vsc_rsp_v = 1'b0;
    sfc_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic zero_in;
    fet = '0;
    drd = '0;
    qdr = '0;
    vwx = '0;
    cxr = '0;
    cwr = '0;
    fbr = '0;
    vbf = '0;
    iwr = '0;
    svr = '0;
    ssr = '0;
    ver = '0;
    fsr = '0;
    vsr = '0;
    rzr = '0;
    dbr = '0;
    bbr = '0;
    rcr = '0;
    dcr = '0;
    blr = '0;
    scr = '0;
    svc = '0;
    vec_pin = '0;
    fsc_pin = '0;
    vsc_pin = '0;
  endtask

  initial begin
    apu_cfg_t cfg;
    zero_in();
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && fsc == '0 &&
          fce == '0 && vsc == '0 && vse == '0 && sfc == '0 && sfe == '0);
    check("profiles keep the objects off",
          !ApuOff.FscEn && !ApuOff.FceEn && !ApuOff.VscEn && !ApuOff.VseEn &&
          !ApuOff.SfcEn && !ApuOff.SfeEn &&
          !ApuP1Transport.FscEn && !ApuP1Transport.FceEn &&
          !ApuP1Transport.VscEn && !ApuP1Transport.VseEn &&
          !ApuP1Transport.SfcEn && !ApuP1Transport.SfeEn &&
          !ApuHarness.FscEn && !ApuHarness.FceEn &&
          !ApuHarness.VscEn && !ApuHarness.VseEn &&
          !ApuHarness.SfcEn && !ApuHarness.SfeEn &&
          !ApuSchedBoth.FscEn && !ApuSchedBoth.FceEn &&
          !ApuSchedBoth.VscEn && !ApuSchedBoth.VseEn &&
          !ApuSchedBoth.SfcEn && !ApuSchedBoth.SfeEn &&
          !ApuBadVirglGrant.FscEn && !ApuBadVirglGrant.FceEn &&
          !ApuBadVirglGrant.VscEn && !ApuBadVirglGrant.VseEn &&
          !ApuBadVirglGrant.SfcEn && !ApuBadVirglGrant.SfeEn);
    cfg = ApuP1Transport;
    cfg.FscEn = 1'b1;
    cfg.FceEn = 1'b1;
    cfg.VscEn = 1'b1;
    cfg.VseEn = 1'b1;
    cfg.SfcEn = 1'b1;
    cfg.SfeEn = 1'b1;
    check("objects do not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.FscEn = 1'b1;
    cfg.FceEn = 1'b1;
    cfg.VscEn = 1'b1;
    cfg.VseEn = 1'b1;
    cfg.SfcEn = 1'b1;
    cfg.SfeEn = 1'b1;
    check("objects do not legalize virgl", !apu_cfg_legal(cfg));
    check("objects place",
          APU_VGPU_FSC_BEAT == 6'd5 && APU_VGPU_FSC_ADDR == 64'h8800B0A0 &&
          APU_VGPU_FSC_LAST == 64'h8800B0C0 && APU_VIRGL_FSC_AT == 32'd176 &&
          APU_VIRGL_FSC_AT == APU_VIRGL_VS_NEXT &&
          APU_VIRGL_FSC_AT + APU_VIRGL_FS_SPAN == APU_VIRGL_VEC_AT &&
          APU_VIRGL_FS_TEXT_AT == APU_VIRGL_FSC_AT + 32'd24 &&
          APU_VIRGL_FS_HDR == 32'h00280401 && APU_VIRGL_FS_WORDS == 32'd40 &&
          APU_VIRGL_FS_DWORDS == 32'd35 && APU_VIRGL_FS_SPAN == 32'd164 &&
          APU_VGPU_VSC_BEAT == 6'd0 && APU_VGPU_VSC_ADDR == 64'h8800B000 &&
          APU_VGPU_VSC_LAST == 64'h8800B020 && APU_VIRGL_VSC_AT == 32'd24 &&
          APU_VIRGL_VSC_AT + APU_VIRGL_VS_SPAN == APU_VIRGL_FSC_AT &&
          APU_VIRGL_VS_TEXT_AT == APU_VIRGL_VSC_AT + 32'd24 &&
          APU_VIRGL_VS_HDR == 32'h00250401 && APU_VIRGL_VS_WORDS == 32'd37 &&
          APU_VIRGL_VS_DWORDS == 32'd32 && APU_VIRGL_VS_SPAN == 32'd152 &&
          APU_VGPU_SFC_BEAT == 6'd0 && APU_VGPU_SFC_ADDR == 64'h8800B000 &&
          APU_VGPU_SFC_ADDR == APU_VGPU_EXEC_ADDR &&
          APU_VGPU_SFC_ADDR == APU_VGPU_VSC_ADDR &&
          APU_VIRGL_SFC_AT == 32'd0 &&
          APU_VIRGL_SFC_AT + APU_VIRGL_SF_SPAN == APU_VIRGL_VSC_AT &&
          APU_VIRGL_SF_HDR == 32'h00050801 && APU_VIRGL_SF_SPAN == 32'd24 &&
          APU_VIRGL_SF_HDR == Cmd0);

    fsc_step(APU_VGPU_FSC_EMPTY, "fragment empty");
    scene_in();
    fsc_step(APU_VGPU_FSC_EMPTY, "vertex elements missing");
    scene_in();
    vec_in();
    fet.beats = 6'd0;
    fsc_step(APU_VGPU_FSC_FAULT, "bad identity");
    scene_in();
    vec_in();
    vec_pin.handle = APU_VIRGL_SV_HANDLE;
    fsc_step(APU_VGPU_FSC_FAULT, "bad vertex elements");
    scene_in();
    vec_in();
    fsc_fail = 1'b1;
    fsc_step(APU_VGPU_FSC_FAULT, "bad beat");
    fsc_bad_hdr = 1'b1;
    fsc_step(APU_VGPU_FSC_FAULT, "bad hdr");
    fsc_bad_handle = 1'b1;
    fsc_step(APU_VGPU_FSC_FAULT, "bad handle");
    fsc_bad_stage = 1'b1;
    fsc_step(APU_VGPU_FSC_FAULT, "bad stage");
    fsc_bad_offlen = 1'b1;
    fsc_step(APU_VGPU_FSC_FAULT, "bad offlen");
    fsc_bad_tokens = 1'b1;
    fsc_step(APU_VGPU_FSC_FAULT, "bad tokens");
    fsc_bad_so = 1'b1;
    fsc_step(APU_VGPU_FSC_FAULT, "bad so");
    fsc_bad_text0 = 1'b1;
    fsc_step(APU_VGPU_FSC_FAULT, "bad text0");
    fsc_step(APU_VGPU_FSC_OK, "fragment shader");
    fsc_step(APU_VGPU_FSC_FAULT, "fragment shader again");
    check("fragment shader stays", fsc_ok(fsc) && fsc.handle != vec_pin.handle);
    fce_step(APU_VGPU_FCE_OK, "keep fragment shader");
    check("fragment shader kept", fce.valid && fce.handle == APU_VIRGL_FS_HANDLE &&
          fce.stage == Frag && fce.text0 == APU_VIRGL_FS_TEXT0 &&
          fce.handle != vec_pin.handle);
    fce_step(APU_VGPU_FCE_FAULT, "fragment shader keep again");
    check("fragment shader keep stays", fce.text0 == APU_VIRGL_FS_TEXT0 &&
          fce.offlen == APU_VIRGL_FS_OFFLEN);

    zero_in();
    vsc_step(APU_VGPU_VSC_EMPTY, "vertex empty");
    scene_in();
    vec_in();
    vsc_step(APU_VGPU_VSC_EMPTY, "fragment shader missing");
    scene_in();
    vec_in();
    fsc_in();
    fsc_pin.handle = APU_VIRGL_VS_HANDLE;
    vsc_step(APU_VGPU_VSC_FAULT, "bad fragment shader");
    scene_in();
    vec_in();
    fsc_in();
    fet.beats = 6'd0;
    vsc_step(APU_VGPU_VSC_FAULT, "bad identity");
    scene_in();
    vec_in();
    fsc_in();
    vsc_fail = 1'b1;
    vsc_step(APU_VGPU_VSC_FAULT, "bad beat");
    vsc_bad_hdr = 1'b1;
    vsc_step(APU_VGPU_VSC_FAULT, "bad hdr");
    vsc_bad_handle = 1'b1;
    vsc_step(APU_VGPU_VSC_FAULT, "bad handle");
    vsc_bad_stage = 1'b1;
    vsc_step(APU_VGPU_VSC_FAULT, "bad stage");
    vsc_bad_offlen = 1'b1;
    vsc_step(APU_VGPU_VSC_FAULT, "bad offlen");
    vsc_bad_tokens = 1'b1;
    vsc_step(APU_VGPU_VSC_FAULT, "bad tokens");
    vsc_bad_so = 1'b1;
    vsc_step(APU_VGPU_VSC_FAULT, "bad so");
    vsc_bad_text0 = 1'b1;
    vsc_step(APU_VGPU_VSC_FAULT, "bad text0");
    vsc_step(APU_VGPU_VSC_OK, "vertex shader");
    vsc_step(APU_VGPU_VSC_FAULT, "vertex shader again");
    check("vertex shader stays", vsc_ok(vsc) && vsc.handle != fsc_pin.handle);
    vse_step(APU_VGPU_VSE_OK, "keep vertex shader");
    check("vertex shader kept", vse.valid && vse.handle == APU_VIRGL_VS_HANDLE &&
          vse.stage == Vstage && vse.text0 == APU_VIRGL_VS_TEXT0 &&
          vse.handle != fsc_pin.handle);
    vse_step(APU_VGPU_VSE_FAULT, "vertex shader keep again");
    check("vertex shader keep stays", vse.text0 == APU_VIRGL_VS_TEXT0 &&
          vse.offlen == APU_VIRGL_VS_OFFLEN);

    zero_in();
    sfc_step(APU_VGPU_SFC_EMPTY, "surface empty");
    scene_in();
    vec_in();
    fsc_in();
    sfc_step(APU_VGPU_SFC_EMPTY, "vertex shader missing");
    scene_in();
    vec_in();
    fsc_in();
    vsc_in();
    vsc_pin.handle = APU_VIRGL_FS_HANDLE;
    sfc_step(APU_VGPU_SFC_FAULT, "bad vertex shader");
    scene_in();
    vec_in();
    fsc_in();
    vsc_in();
    fet.beats = 6'd0;
    sfc_step(APU_VGPU_SFC_FAULT, "bad identity");
    scene_in();
    vec_in();
    fsc_in();
    vsc_in();
    sfc_fail = 1'b1;
    sfc_step(APU_VGPU_SFC_FAULT, "bad beat");
    sfc_bad_hdr = 1'b1;
    sfc_step(APU_VGPU_SFC_FAULT, "bad hdr");
    sfc_bad_handle = 1'b1;
    sfc_step(APU_VGPU_SFC_FAULT, "bad handle");
    sfc_bad_res = 1'b1;
    sfc_step(APU_VGPU_SFC_FAULT, "bad resource");
    sfc_bad_fmt = 1'b1;
    sfc_step(APU_VGPU_SFC_FAULT, "bad format");
    sfc_bad_z0 = 1'b1;
    sfc_step(APU_VGPU_SFC_FAULT, "bad zero");
    sfc_bad_z1 = 1'b1;
    sfc_step(APU_VGPU_SFC_FAULT, "bad zero2");
    sfc_step(APU_VGPU_SFC_OK, "surface");
    sfc_step(APU_VGPU_SFC_FAULT, "surface again");
    check("surface stays", sfc_ok(sfc) && sfc.handle != vsc_pin.handle &&
          sfc.resource == APU_VIRGL_RES_RT);
    sfe_step(APU_VGPU_SFE_OK, "keep surface");
    check("surface kept", sfe.valid && sfe.hdr == APU_VIRGL_SF_HDR &&
          sfe.handle == APU_VIRGL_SURFACE_HANDLE && sfe.resource == APU_VIRGL_RES_RT &&
          sfe.format == APU_VIRGL_FMT_B8G8R8X8 && sfe.handle != vsc_pin.handle);
    sfe_step(APU_VGPU_SFE_FAULT, "surface keep again");
    check("surface keep stays", sfe.handle == APU_VIRGL_SURFACE_HANDLE &&
          sfe.format == APU_VIRGL_FMT_B8G8R8X8);

    pulse_reset();
    check("reset clears", fsc == '0 && fce == '0 && vsc == '0 && vse == '0 &&
          sfc == '0 && sfe == '0);
    zero_in();
    fsc_step(APU_VGPU_FSC_EMPTY, "fragment after reset");
    vsc_step(APU_VGPU_VSC_EMPTY, "vertex after reset");
    sfc_step(APU_VGPU_SFC_EMPTY, "surface after reset");
    fce_step(APU_VGPU_FCE_EMPTY, "fragment keep after reset");
    vse_step(APU_VGPU_VSE_EMPTY, "vertex keep after reset");
    sfe_step(APU_VGPU_SFE_EMPTY, "surface keep after reset");

    if (errors != 0) $fatal(1, "APU vgpu obj errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_obj cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
