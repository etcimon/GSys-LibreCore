// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the sampler-state CREATE_OBJECT at byte 408 after the blend
// object is accepted. Beat 12 at 64'h8800B180 carries the header
// 32'h00090701 and handle 6. Beat 13 at 64'h8800B1A0 carries the wrap
// word 32'h00002292 and max LOD 32'h42000000. The other body words are
// 0 and are not kept. No texture is bound. The sampler-view tail in
// beat 12 is not part of this check. This is not g6lc_apu_vgpu_ss and
// not g6lc_apu_vgpu_avail. A failed beat stops the read; the request
// can be repeated. TEX is not executed.

// SamplerStateObjectRead (scr): Sampler-state object of the fetched draw.
module g6lc_apu_vgpu_scr
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
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_scr_cpl_t cpl_o,
  output apu_vgpu_scr_t scr_o,
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
      beat_bad = data[223:192] != APU_VIRGL_SS_HDR ||
                 data[255:224] != APU_VIRGL_SS_HANDLE;
    end else begin
      beat_bad = data[31:0] != APU_VIRGL_SSTATE_S0 ||
                 data[63:32] != 32'h0 || data[95:64] != 32'h0 ||
                 data[127:96] != APU_VIRGL_SSTATE_MAX_LOD ||
                 data[159:128] != 32'h0 || data[191:160] != 32'h0 ||
                 data[223:192] != 32'h0 || data[255:224] != 32'h0;
    end
  endfunction

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign scr_o = '0;
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
                        (|rcr_i) | (|dcr_i) | (|blr_i) | (|rd_rsp_addr_i) |
                        (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_scr_cpl_t cpl_q;
    apu_vgpu_scr_t scr_q;
    logic beat_q;
    logic [31:0] hdr_q, handle_q, s0_q, max_lod_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'(APU_VGPU_BEAT_BYTES);
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_scr_cpl_t'('0);
    assign scr_o = scr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        scr_q <= '0;
        beat_q <= 1'b0;
        hdr_q <= '0;
        handle_q <= '0;
        s0_q <= '0;
        max_lod_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (scr_q.valid) begin
            cpl_q.status <= APU_VGPU_SCR_FAULT;
            state_q <= Done;
          end else if (!fet_i.valid || !drd_i.valid || !qdr_i.valid ||
                       !vwx_i.valid || !cxr_i.valid || !cwr_i.valid ||
                       !fbr_i.valid || !vbf_i.valid || !iwr_i.valid ||
                       !svr_i.valid || !ssr_i.valid || !ver_i.valid ||
                       !fsr_i.valid || !vsr_i.valid || !rzr_i.valid ||
                       !dbr_i.valid || !bbr_i.valid || !rcr_i.valid ||
                       !dcr_i.valid || !blr_i.valid) begin
            cpl_q.status <= APU_VGPU_SCR_EMPTY;
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
                       blr_i.handle == ssr_i.handle) begin
            cpl_q.status <= APU_VGPU_SCR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            hdr_q <= '0;
            handle_q <= '0;
            s0_q <= '0;
            max_lod_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_SCR_ADDR;
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
            addr_q <= APU_VGPU_SCR_LAST;
            state_q <= Issue;
          end else begin
            s0_q <= rd_rsp_data_i[31:0];
            max_lod_q <= rd_rsp_data_i[127:96];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || hdr_q != APU_VIRGL_SS_HDR ||
              handle_q != APU_VIRGL_SS_HANDLE ||
              s0_q != APU_VIRGL_SSTATE_S0 ||
              max_lod_q != APU_VIRGL_SSTATE_MAX_LOD ||
              hdr_q == handle_q || hdr_q == APU_VIRGL_SSB_HDR ||
              s0_q == handle_q || max_lod_q == handle_q ||
              handle_q != ssr_i.handle || handle_q == blr_i.handle)
            cpl_q.status <= APU_VGPU_SCR_FAULT;
          else begin
            scr_q.valid <= 1'b1;
            scr_q.hdr <= hdr_q;
            scr_q.handle <= handle_q;
            scr_q.s0 <= s0_q;
            scr_q.max_lod <= max_lod_q;
            cpl_q.status <= APU_VGPU_SCR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(scr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SCR_OK |->
        scr_o.valid && scr_o.hdr == APU_VIRGL_SS_HDR &&
        scr_o.handle == APU_VIRGL_SS_HANDLE &&
        scr_o.s0 == APU_VIRGL_SSTATE_S0 &&
        scr_o.max_lod == APU_VIRGL_SSTATE_MAX_LOD &&
        scr_o.hdr != scr_o.handle && scr_o.hdr != APU_VIRGL_SSB_HDR &&
        scr_o.handle != APU_VIRGL_BL_HANDLE && scr_o.s0 != scr_o.handle);
    `endif
  end
endmodule

// SamplerStateObjectRead (scr) enable-0 fixture: Sampler-state object of the fetched draw.
module g6lc_apu_vgpu_scr_fixture
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
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_scr_cpl_t cpl_o,
  output apu_vgpu_scr_t scr_o,
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
  g6lc_apu_vgpu_scr #(.Enable(Enable)) i_dut (.*);
endmodule
