// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the depth-stencil header and handle. A second store keeps the
// first. The four state words are not kept. No depth test is run.

// DepthStencilObjectReadKeep (dck): The header and the handle.
module g6lc_apu_vgpu_dck
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_dcr_t dcr_i,
  input  apu_vgpu_rcr_t rcr_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_dck_cpl_t cpl_o,
  output apu_vgpu_dck_t dck_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign dck_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|dcr_i) | (|rcr_i) | (|iwr_i) | (|fet_i) | (|qdr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_dck_cpl_t cpl_q;
    apu_vgpu_dck_t dck_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_dck_cpl_t'('0);
    assign dck_o = dck_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        dck_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (dck_q.valid) begin
            cpl_q.status <= APU_VGPU_DCK_FAULT;
          end else if (!dcr_i.valid || !rcr_i.valid || !iwr_i.valid ||
                       !fet_i.valid || !qdr_i.valid) begin
            cpl_q.status <= APU_VGPU_DCK_EMPTY;
          end else if (dcr_i.hdr != APU_VIRGL_DS_HDR ||
                       dcr_i.handle != APU_VIRGL_DS_HANDLE ||
                       dcr_i.hdr == dcr_i.handle ||
                       dcr_i.hdr == APU_VIRGL_DB_HDR ||
                       dcr_i.handle == rcr_i.handle ||
                       rcr_i.hdr != APU_VIRGL_RZ_HDR ||
                       rcr_i.handle != APU_VIRGL_RZ_HANDLE ||
                       rcr_i.hdr == rcr_i.handle ||
                       iwr_i.resource != APU_VIRGL_RES_VBO ||
                       iwr_i.nbytes != APU_VIRGL_VBO_BYTES ||
                       iwr_i.resource == iwr_i.nbytes ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS) begin
            cpl_q.status <= APU_VGPU_DCK_FAULT;
          end else begin
            dck_q.valid <= 1'b1;
            dck_q.hdr <= dcr_i.hdr;
            dck_q.handle <= dcr_i.handle;
            cpl_q.status <= APU_VGPU_DCK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(dck_o));
    `endif
  end
endmodule

// DepthStencilObjectReadKeep (dck) enable-0 fixture: The header and the handle.
module g6lc_apu_vgpu_dck_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_dcr_t dcr_i,
  input  apu_vgpu_rcr_t rcr_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_dck_cpl_t cpl_o,
  output apu_vgpu_dck_t dck_o
);
  g6lc_apu_vgpu_dck #(.Enable(Enable)) i_dut (.*);
endmodule
