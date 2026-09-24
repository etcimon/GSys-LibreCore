// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the vertex-shader header, handle, stage, length, token count, and
// first text dword. A second store keeps the first. The shader is not run.

module g6lc_apu_vgpu_vse
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_vsc_t vsc_i,
  input  apu_vgpu_fsc_t fsc_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vse_cpl_t cpl_o,
  output apu_vgpu_vse_t vse_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] Frag = 32'(APU_VIRGL_SHADER_FRAGMENT);
  localparam logic [31:0] Vstage = 32'(APU_VIRGL_SHADER_VERTEX);

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vse_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|vsc_i) | (|fsc_i) | (|iwr_i) | (|fet_i) | (|qdr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_vse_cpl_t cpl_q;
    apu_vgpu_vse_t vse_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_vse_cpl_t'('0);
    assign vse_o = vse_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        vse_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (vse_q.valid) begin
            cpl_q.status <= APU_VGPU_VSE_FAULT;
          end else if (!vsc_i.valid || !fsc_i.valid || !iwr_i.valid ||
                       !fet_i.valid || !qdr_i.valid) begin
            cpl_q.status <= APU_VGPU_VSE_EMPTY;
          end else if (vsc_i.hdr != APU_VIRGL_VS_HDR ||
                       vsc_i.handle != APU_VIRGL_VS_HANDLE ||
                       vsc_i.stage != Vstage ||
                       vsc_i.offlen != APU_VIRGL_VS_OFFLEN ||
                       vsc_i.tokens != APU_VIRGL_VS_TOKENS ||
                       vsc_i.text0 != APU_VIRGL_VS_TEXT0 ||
                       vsc_i.hdr == vsc_i.handle ||
                       vsc_i.handle == APU_VIRGL_FS_HANDLE ||
                       vsc_i.text0 == APU_VIRGL_FS_TEXT0 ||
                       vsc_i.handle == fsc_i.handle ||
                       fsc_i.hdr != APU_VIRGL_FS_HDR ||
                       fsc_i.handle != APU_VIRGL_FS_HANDLE ||
                       fsc_i.stage != Frag ||
                       fsc_i.text0 != APU_VIRGL_FS_TEXT0 ||
                       fsc_i.handle == vsc_i.handle ||
                       iwr_i.resource != APU_VIRGL_RES_VBO ||
                       iwr_i.nbytes != APU_VIRGL_VBO_BYTES ||
                       iwr_i.resource == iwr_i.nbytes ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS) begin
            cpl_q.status <= APU_VGPU_VSE_FAULT;
          end else begin
            vse_q.valid <= 1'b1;
            vse_q.hdr <= vsc_i.hdr;
            vse_q.handle <= vsc_i.handle;
            vse_q.stage <= vsc_i.stage;
            vse_q.offlen <= vsc_i.offlen;
            vse_q.tokens <= vsc_i.tokens;
            vse_q.text0 <= vsc_i.text0;
            cpl_q.status <= APU_VGPU_VSE_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(vse_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_vse_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_vsc_t vsc_i,
  input  apu_vgpu_fsc_t fsc_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vse_cpl_t cpl_o,
  output apu_vgpu_vse_t vse_o
);
  g6lc_apu_vgpu_vse #(.Enable(Enable)) i_dut (.*);
endmodule
