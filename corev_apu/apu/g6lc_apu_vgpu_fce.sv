// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the fragment-shader header, handle, stage, length, token count,
// and first text dword. A second store keeps the first. The rest of the
// text is not kept. The shader is not run.

module g6lc_apu_vgpu_fce
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fsc_t fsc_i,
  input  apu_vgpu_vec_t vec_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_fce_cpl_t cpl_o,
  output apu_vgpu_fce_t fce_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] Frag = 32'(APU_VIRGL_SHADER_FRAGMENT);

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign fce_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|fsc_i) | (|vec_i) | (|iwr_i) | (|fet_i) | (|qdr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_fce_cpl_t cpl_q;
    apu_vgpu_fce_t fce_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_fce_cpl_t'('0);
    assign fce_o = fce_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        fce_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (fce_q.valid) begin
            cpl_q.status <= APU_VGPU_FCE_FAULT;
          end else if (!fsc_i.valid || !vec_i.valid || !iwr_i.valid ||
                       !fet_i.valid || !qdr_i.valid) begin
            cpl_q.status <= APU_VGPU_FCE_EMPTY;
          end else if (fsc_i.hdr != APU_VIRGL_FS_HDR ||
                       fsc_i.handle != APU_VIRGL_FS_HANDLE ||
                       fsc_i.stage != Frag ||
                       fsc_i.offlen != APU_VIRGL_FS_OFFLEN ||
                       fsc_i.tokens != APU_VIRGL_FS_TOKENS ||
                       fsc_i.text0 != APU_VIRGL_FS_TEXT0 ||
                       fsc_i.hdr == fsc_i.handle ||
                       fsc_i.handle == APU_VIRGL_VS_HANDLE ||
                       fsc_i.text0 == APU_VIRGL_VS_TEXT0 ||
                       fsc_i.handle == vec_i.handle ||
                       vec_i.hdr != APU_VIRGL_VE_HDR ||
                       vec_i.handle != APU_VIRGL_VE_HANDLE ||
                       vec_i.off0 != 32'h0 ||
                       vec_i.fmt0 != APU_VIRGL_FMT_R32G32B32A32_FLOAT ||
                       vec_i.off1 != 32'd16 ||
                       vec_i.fmt1 != APU_VIRGL_FMT_R32G32_FLOAT ||
                       vec_i.hdr == vec_i.handle ||
                       vec_i.handle == fsc_i.handle ||
                       iwr_i.resource != APU_VIRGL_RES_VBO ||
                       iwr_i.nbytes != APU_VIRGL_VBO_BYTES ||
                       iwr_i.resource == iwr_i.nbytes ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS) begin
            cpl_q.status <= APU_VGPU_FCE_FAULT;
          end else begin
            fce_q.valid <= 1'b1;
            fce_q.hdr <= fsc_i.hdr;
            fce_q.handle <= fsc_i.handle;
            fce_q.stage <= fsc_i.stage;
            fce_q.offlen <= fsc_i.offlen;
            fce_q.tokens <= fsc_i.tokens;
            fce_q.text0 <= fsc_i.text0;
            cpl_q.status <= APU_VGPU_FCE_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(fce_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_fce_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fsc_t fsc_i,
  input  apu_vgpu_vec_t vec_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_fce_cpl_t cpl_o,
  output apu_vgpu_fce_t fce_o
);
  g6lc_apu_vgpu_fce #(.Enable(Enable)) i_dut (.*);
endmodule
