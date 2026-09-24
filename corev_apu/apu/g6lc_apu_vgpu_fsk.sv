// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the fragment-shader handle and stage. A second store keeps
// the first. The shader is not run.

module g6lc_apu_vgpu_fsk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fsr_t fsr_i,
  input  apu_vgpu_ver_t ver_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_fsk_cpl_t cpl_o,
  output apu_vgpu_fsk_t fsk_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};
  localparam logic [31:0] Stage = 32'(APU_VIRGL_SHADER_FRAGMENT);

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign fsk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|fsr_i) | (|ver_i) | (|iwr_i) | (|fet_i) | (|qdr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_fsk_cpl_t cpl_q;
    apu_vgpu_fsk_t fsk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_fsk_cpl_t'('0);
    assign fsk_o = fsk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        fsk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (fsk_q.valid) begin
            cpl_q.status <= APU_VGPU_FSK_FAULT;
          end else if (!fsr_i.valid || !ver_i.valid || !iwr_i.valid ||
                       !fet_i.valid || !qdr_i.valid) begin
            cpl_q.status <= APU_VGPU_FSK_EMPTY;
          end else if (fsr_i.handle != APU_VIRGL_FS_HANDLE ||
                       fsr_i.stage != Stage ||
                       fsr_i.handle == fsr_i.stage ||
                       fsr_i.handle == ver_i.handle ||
                       fsr_i.handle == APU_VIRGL_VS_HANDLE ||
                       ver_i.hdr != APU_VIRGL_VEB_HDR ||
                       ver_i.handle != APU_VIRGL_VE_HANDLE ||
                       ver_i.hdr == ver_i.handle ||
                       iwr_i.resource != APU_VIRGL_RES_VBO ||
                       iwr_i.nbytes != APU_VIRGL_VBO_BYTES ||
                       iwr_i.resource == iwr_i.nbytes ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS) begin
            cpl_q.status <= APU_VGPU_FSK_FAULT;
          end else begin
            fsk_q.valid <= 1'b1;
            fsk_q.handle <= fsr_i.handle;
            fsk_q.stage <= fsr_i.stage;
            cpl_q.status <= APU_VGPU_FSK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(fsk_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_fsk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fsr_t fsr_i,
  input  apu_vgpu_ver_t ver_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_fsk_cpl_t cpl_o,
  output apu_vgpu_fsk_t fsk_o
);
  g6lc_apu_vgpu_fsk #(.Enable(Enable)) i_dut (.*);
endmodule
