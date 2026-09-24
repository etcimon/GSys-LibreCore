// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the sampler-view header, handle, resource, format, and swizzle.
// A second store keeps the first. The zero body words are not kept.
// No texture is bound.

module g6lc_apu_vgpu_vck
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_svc_t svc_i,
  input  apu_vgpu_scr_t scr_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vck_cpl_t cpl_o,
  output apu_vgpu_vck_t vck_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vck_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|svc_i) | (|scr_i) | (|iwr_i) | (|fet_i) | (|qdr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_vck_cpl_t cpl_q;
    apu_vgpu_vck_t vck_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_vck_cpl_t'('0);
    assign vck_o = vck_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        vck_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (vck_q.valid) begin
            cpl_q.status <= APU_VGPU_VCK_FAULT;
          end else if (!svc_i.valid || !scr_i.valid || !iwr_i.valid ||
                       !fet_i.valid || !qdr_i.valid) begin
            cpl_q.status <= APU_VGPU_VCK_EMPTY;
          end else if (svc_i.hdr != APU_VIRGL_SV_HDR ||
                       svc_i.handle != APU_VIRGL_SV_HANDLE ||
                       svc_i.resource != APU_VIRGL_RES_SCAN ||
                       svc_i.format != APU_VIRGL_SV_FMT ||
                       svc_i.swizzle != APU_VIRGL_SWIZZLE_IDENTITY ||
                       svc_i.hdr == svc_i.handle ||
                       svc_i.hdr == APU_VIRGL_SVB_HDR ||
                       svc_i.handle == scr_i.handle ||
                       svc_i.resource == svc_i.handle ||
                       scr_i.hdr != APU_VIRGL_SS_HDR ||
                       scr_i.handle != APU_VIRGL_SS_HANDLE ||
                       scr_i.s0 != APU_VIRGL_SSTATE_S0 ||
                       scr_i.max_lod != APU_VIRGL_SSTATE_MAX_LOD ||
                       scr_i.hdr == scr_i.handle ||
                       iwr_i.resource != APU_VIRGL_RES_VBO ||
                       iwr_i.nbytes != APU_VIRGL_VBO_BYTES ||
                       iwr_i.resource == iwr_i.nbytes ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS) begin
            cpl_q.status <= APU_VGPU_VCK_FAULT;
          end else begin
            vck_q.valid <= 1'b1;
            vck_q.hdr <= svc_i.hdr;
            vck_q.handle <= svc_i.handle;
            vck_q.resource <= svc_i.resource;
            vck_q.format <= svc_i.format;
            vck_q.swizzle <= svc_i.swizzle;
            cpl_q.status <= APU_VGPU_VCK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(vck_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_vck_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_svc_t svc_i,
  input  apu_vgpu_scr_t scr_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vck_cpl_t cpl_o,
  output apu_vgpu_vck_t vck_o
);
  g6lc_apu_vgpu_vck #(.Enable(Enable)) i_dut (.*);
endmodule
