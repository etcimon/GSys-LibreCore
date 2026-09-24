// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the vertex-shader CREATE_OBJECT at byte 24 after the fragment
// shader is accepted. Beat 0 at 64'h8800B000 carries header 32'h00250401
// and handle 2 in its last two words. Beat 1 at 64'h8800B020 carries
// the vertex stage, length 125, token count 300, a zero stream-out word,
// and text0 32'h54524556. The surface in the same first beat is not this
// check. The rest of the text stays in the execbuffer. The shader is not
// run. This is not g6lc_apu_vgpu_sh, not g6lc_apu_vgpu_vst, and not
// g6lc_apu_vgpu_avail. A failed beat stops the read.

module g6lc_apu_vgpu_vsc
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_drd_t drd_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  apu_vgpu_vwx_t vwx_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_fbr_t fbr_i,
  input  apu_vgpu_vbf_t vbf_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_svr_t svr_i,
  input  apu_vgpu_ssr_t ssr_i,
  input  apu_vgpu_ver_t ver_i,
  input  apu_vgpu_fsr_t fsr_i,
  input  apu_vgpu_vsr_t vsr_i,
  input  apu_vgpu_rzr_t rzr_i,
  input  apu_vgpu_dbr_t dbr_i,
  input  apu_vgpu_bbr_t bbr_i,
  input  apu_vgpu_rcr_t rcr_i,
  input  apu_vgpu_dcr_t dcr_i,
  input  apu_vgpu_blr_t blr_i,
  input  apu_vgpu_scr_t scr_i,
  input  apu_vgpu_svc_t svc_i,
  input  apu_vgpu_vec_t vec_i,
  input  apu_vgpu_fsc_t fsc_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vsc_cpl_t cpl_o,
  output apu_vgpu_vsc_t vsc_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] Frag = 32'(APU_VIRGL_SHADER_FRAGMENT);
  localparam logic [31:0] Vstage = 32'(APU_VIRGL_SHADER_VERTEX);

  function automatic logic beat_bad(input logic beat, input logic [255:0] data);
    if (beat == 1'b0) begin
      beat_bad = data[223:192] != APU_VIRGL_VS_HDR ||
                 data[255:224] != APU_VIRGL_VS_HANDLE;
    end else begin
      beat_bad = data[31:0] != Vstage ||
                 data[63:32] != APU_VIRGL_VS_OFFLEN ||
                 data[95:64] != APU_VIRGL_VS_TOKENS ||
                 data[127:96] != 32'h0 ||
                 data[159:128] != APU_VIRGL_VS_TEXT0;
    end
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vsc_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|fet_i) | (|drd_i) |
                        (|qdr_i) | (|vwx_i) | (|cxr_i) | (|cwr_i) | (|fbr_i) |
                        (|vbf_i) | (|iwr_i) | (|svr_i) | (|ssr_i) | (|ver_i) |
                        (|fsr_i) | (|vsr_i) | (|rzr_i) | (|dbr_i) | (|bbr_i) |
                        (|rcr_i) | (|dcr_i) | (|blr_i) | (|scr_i) | (|svc_i) |
                        (|vec_i) | (|fsc_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                        (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_vsc_cpl_t cpl_q;
    apu_vgpu_vsc_t vsc_q;
    logic beat_q;
    logic [31:0] hdr_q, handle_q, stage_q, offlen_q, tokens_q, text0_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_vsc_cpl_t'('0);
    assign vsc_o = vsc_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        vsc_q <= '0;
        beat_q <= 1'b0;
        hdr_q <= '0;
        handle_q <= '0;
        stage_q <= '0;
        offlen_q <= '0;
        tokens_q <= '0;
        text0_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (vsc_q.valid) begin
            cpl_q.status <= APU_VGPU_VSC_FAULT;
            state_q <= Done;
          end else if (!fet_i.valid || !drd_i.valid || !qdr_i.valid ||
                       !vwx_i.valid || !cxr_i.valid || !cwr_i.valid ||
                       !fbr_i.valid || !vbf_i.valid || !iwr_i.valid ||
                       !svr_i.valid || !ssr_i.valid || !ver_i.valid ||
                       !fsr_i.valid || !vsr_i.valid || !rzr_i.valid ||
                       !dbr_i.valid || !bbr_i.valid || !rcr_i.valid ||
                       !dcr_i.valid || !blr_i.valid || !scr_i.valid ||
                       !svc_i.valid || !vec_i.valid || !fsc_i.valid) begin
            cpl_q.status <= APU_VGPU_VSC_EMPTY;
            state_q <= Done;
          end else if (fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS ||
                       drd_i.count != APU_VIRGL_VERT_COUNT ||
                       drd_i.prim != APU_VIRGL_PRIM_STRIP ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE ||
                       qdr_i.last != APU_VIRGL_F32_ONE ||
                       vwx_i.x_neg != 16'd0 || vwx_i.y_neg != 16'd0 ||
                       vwx_i.x_pos != 16'd640 || vwx_i.y_pos != 16'd480 ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480 ||
                       cwr_i.word != APU_VGPU_CLEAR_WORD ||
                       fbr_i.surface != APU_VIRGL_SURFACE_HANDLE ||
                       fbr_i.word != APU_VGPU_CLEAR_WORD ||
                       vbf_i.stride != APU_VIRGL_VERT_STRIDE ||
                       vbf_i.offset != 32'h0 ||
                       vbf_i.resource != APU_VIRGL_RES_VBO ||
                       iwr_i.resource != APU_VIRGL_RES_VBO ||
                       iwr_i.nbytes != APU_VIRGL_VBO_BYTES ||
                       iwr_i.resource == iwr_i.nbytes ||
                       iwr_i.resource != vbf_i.resource ||
                       svr_i.stage != Frag || svr_i.slot != 32'h0 ||
                       svr_i.handle != APU_VIRGL_SV_HANDLE ||
                       svr_i.stage == svr_i.slot ||
                       svr_i.handle == svr_i.stage ||
                       ssr_i.stage != Frag || ssr_i.slot != 32'h0 ||
                       ssr_i.handle != APU_VIRGL_SS_HANDLE ||
                       ssr_i.stage == ssr_i.slot ||
                       ssr_i.handle == ssr_i.stage ||
                       ssr_i.handle == svr_i.handle ||
                       ver_i.hdr != APU_VIRGL_VEB_HDR ||
                       ver_i.handle != APU_VIRGL_VE_HANDLE ||
                       ver_i.hdr == ver_i.handle ||
                       fsr_i.handle != APU_VIRGL_FS_HANDLE ||
                       fsr_i.stage != Frag ||
                       fsr_i.handle == fsr_i.stage ||
                       fsr_i.handle == APU_VIRGL_VS_HANDLE ||
                       fsr_i.handle == ver_i.handle ||
                       vsr_i.handle != APU_VIRGL_VS_HANDLE ||
                       vsr_i.stage != Vstage ||
                       vsr_i.handle == vsr_i.stage ||
                       vsr_i.handle == fsr_i.handle ||
                       vsr_i.stage == fsr_i.stage ||
                       rzr_i.hdr != APU_VIRGL_RB_HDR ||
                       rzr_i.handle != APU_VIRGL_RZ_HANDLE ||
                       rzr_i.hdr == rzr_i.handle ||
                       rzr_i.handle == vsr_i.handle ||
                       dbr_i.hdr != APU_VIRGL_DB_HDR ||
                       dbr_i.handle != APU_VIRGL_DS_HANDLE ||
                       dbr_i.hdr == dbr_i.handle ||
                       dbr_i.handle == rzr_i.handle ||
                       bbr_i.hdr != APU_VIRGL_BB_HDR ||
                       bbr_i.handle != APU_VIRGL_BL_HANDLE ||
                       bbr_i.hdr == bbr_i.handle ||
                       bbr_i.handle == dbr_i.handle ||
                       bbr_i.handle == rzr_i.handle ||
                       rcr_i.hdr != APU_VIRGL_RZ_HDR ||
                       rcr_i.handle != APU_VIRGL_RZ_HANDLE ||
                       rcr_i.hdr == rcr_i.handle ||
                       rcr_i.hdr == APU_VIRGL_RB_HDR ||
                       rcr_i.handle == bbr_i.handle ||
                       rcr_i.handle == dbr_i.handle ||
                       dcr_i.hdr != APU_VIRGL_DS_HDR ||
                       dcr_i.handle != APU_VIRGL_DS_HANDLE ||
                       dcr_i.hdr == dcr_i.handle ||
                       dcr_i.hdr == APU_VIRGL_DB_HDR ||
                       dcr_i.handle == rcr_i.handle ||
                       dcr_i.handle == bbr_i.handle ||
                       blr_i.hdr != APU_VIRGL_BL_HDR ||
                       blr_i.handle != APU_VIRGL_BL_HANDLE ||
                       blr_i.s2 != APU_VIRGL_BLEND_S2 ||
                       blr_i.hdr == blr_i.handle ||
                       blr_i.hdr == APU_VIRGL_BB_HDR ||
                       blr_i.s2 == blr_i.handle ||
                       blr_i.handle == dcr_i.handle ||
                       blr_i.handle == ssr_i.handle ||
                       scr_i.hdr != APU_VIRGL_SS_HDR ||
                       scr_i.handle != APU_VIRGL_SS_HANDLE ||
                       scr_i.s0 != APU_VIRGL_SSTATE_S0 ||
                       scr_i.max_lod != APU_VIRGL_SSTATE_MAX_LOD ||
                       scr_i.hdr == scr_i.handle ||
                       scr_i.hdr == APU_VIRGL_SSB_HDR ||
                       scr_i.handle == blr_i.handle ||
                       scr_i.handle == svr_i.handle ||
                       svc_i.hdr != APU_VIRGL_SV_HDR ||
                       svc_i.handle != APU_VIRGL_SV_HANDLE ||
                       svc_i.resource != APU_VIRGL_RES_SCAN ||
                       svc_i.format != APU_VIRGL_SV_FMT ||
                       svc_i.swizzle != APU_VIRGL_SWIZZLE_IDENTITY ||
                       svc_i.hdr == svc_i.handle ||
                       svc_i.hdr == APU_VIRGL_SVB_HDR ||
                       svc_i.handle == scr_i.handle ||
                       svc_i.handle == ver_i.handle ||
                       vec_i.hdr != APU_VIRGL_VE_HDR ||
                       vec_i.handle != APU_VIRGL_VE_HANDLE ||
                       vec_i.off0 != 32'h0 ||
                       vec_i.fmt0 != APU_VIRGL_FMT_R32G32B32A32_FLOAT ||
                       vec_i.off1 != 32'd16 ||
                       vec_i.fmt1 != APU_VIRGL_FMT_R32G32_FLOAT ||
                       vec_i.hdr == vec_i.handle ||
                       vec_i.hdr == APU_VIRGL_VEB_HDR ||
                       vec_i.fmt0 == vec_i.fmt1 ||
                       vec_i.off1 == vec_i.off0 ||
                       vec_i.handle == svc_i.handle ||
                       vec_i.handle != ver_i.handle ||
                       fsc_i.hdr != APU_VIRGL_FS_HDR ||
                       fsc_i.handle != APU_VIRGL_FS_HANDLE ||
                       fsc_i.stage != Frag ||
                       fsc_i.offlen != APU_VIRGL_FS_OFFLEN ||
                       fsc_i.tokens != APU_VIRGL_FS_TOKENS ||
                       fsc_i.text0 != APU_VIRGL_FS_TEXT0 ||
                       fsc_i.hdr == fsc_i.handle ||
                       fsc_i.handle == APU_VIRGL_VS_HANDLE ||
                       fsc_i.text0 == APU_VIRGL_VS_TEXT0 ||
                       fsc_i.handle == vec_i.handle ||
                       fsc_i.handle != fsr_i.handle ||
                       fsc_i.stage != fsr_i.stage) begin
            cpl_q.status <= APU_VGPU_VSC_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            hdr_q <= '0;
            handle_q <= '0;
            stage_q <= '0;
            offlen_q <= '0;
            tokens_q <= '0;
            text0_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_VSC_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'(APU_VGPU_BEAT_BYTES);
          if (bad_bus || beat_bad(beat_q, rd_rsp_data_i)) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 1'b0) begin
            hdr_q <= rd_rsp_data_i[223:192];
            handle_q <= rd_rsp_data_i[255:224];
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_VSC_LAST;
            state_q <= Issue;
          end else begin
            stage_q <= rd_rsp_data_i[31:0];
            offlen_q <= rd_rsp_data_i[63:32];
            tokens_q <= rd_rsp_data_i[95:64];
            text0_q <= rd_rsp_data_i[159:128];
            state_q <= Commit;
          end
        end
        Commit: begin
          logic [31:0] dwords, words;
          dwords = (offlen_q + 32'd3) >> 2;
          words = 32'd5 + dwords;
          if (bad_q || hdr_q != APU_VIRGL_VS_HDR ||
              handle_q != APU_VIRGL_VS_HANDLE ||
              stage_q != Vstage ||
              offlen_q != APU_VIRGL_VS_OFFLEN ||
              tokens_q != APU_VIRGL_VS_TOKENS ||
              text0_q != APU_VIRGL_VS_TEXT0 ||
              words != {16'h0, hdr_q[31:16]} ||
              offlen_q == 32'h0 || offlen_q > APU_VGPU_SUB_MAX ||
              hdr_q == handle_q || hdr_q == APU_VIRGL_VSB_HDR ||
              handle_q == APU_VIRGL_FS_HANDLE ||
              text0_q == APU_VIRGL_FS_TEXT0 ||
              handle_q != vsr_i.handle || stage_q != vsr_i.stage ||
              handle_q == fsc_i.handle || handle_q == vec_i.handle)
            cpl_q.status <= APU_VGPU_VSC_FAULT;
          else begin
            vsc_q.valid <= 1'b1;
            vsc_q.hdr <= hdr_q;
            vsc_q.handle <= handle_q;
            vsc_q.stage <= stage_q;
            vsc_q.offlen <= offlen_q;
            vsc_q.tokens <= tokens_q;
            vsc_q.text0 <= text0_q;
            cpl_q.status <= APU_VGPU_VSC_OK;
          end
          state_q <= Done;
        end
        Done: begin
          if (!armed_q) armed_q <= 1'b1;
          else if (cpl_ready_i) begin
            armed_q <= 1'b0;
            state_q <= Idle;
          end
        end
        default: state_q <= Idle;
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(vsc_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_VSC_OK |->
        vsc_o.valid && vsc_o.hdr == APU_VIRGL_VS_HDR &&
        vsc_o.handle == APU_VIRGL_VS_HANDLE && vsc_o.stage == Vstage &&
        vsc_o.offlen == APU_VIRGL_VS_OFFLEN &&
        vsc_o.tokens == APU_VIRGL_VS_TOKENS &&
        vsc_o.text0 == APU_VIRGL_VS_TEXT0 &&
        vsc_o.hdr != vsc_o.handle &&
        vsc_o.handle != APU_VIRGL_FS_HANDLE &&
        vsc_o.text0 != APU_VIRGL_FS_TEXT0);
    `endif
  end
endmodule

module g6lc_apu_vgpu_vsc_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_drd_t drd_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  apu_vgpu_vwx_t vwx_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_fbr_t fbr_i,
  input  apu_vgpu_vbf_t vbf_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_svr_t svr_i,
  input  apu_vgpu_ssr_t ssr_i,
  input  apu_vgpu_ver_t ver_i,
  input  apu_vgpu_fsr_t fsr_i,
  input  apu_vgpu_vsr_t vsr_i,
  input  apu_vgpu_rzr_t rzr_i,
  input  apu_vgpu_dbr_t dbr_i,
  input  apu_vgpu_bbr_t bbr_i,
  input  apu_vgpu_rcr_t rcr_i,
  input  apu_vgpu_dcr_t dcr_i,
  input  apu_vgpu_blr_t blr_i,
  input  apu_vgpu_scr_t scr_i,
  input  apu_vgpu_svc_t svc_i,
  input  apu_vgpu_vec_t vec_i,
  input  apu_vgpu_fsc_t fsc_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vsc_cpl_t cpl_o,
  output apu_vgpu_vsc_t vsc_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  g6lc_apu_vgpu_vsc #(.Enable(Enable)) i_dut (.*);
endmodule
