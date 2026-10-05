// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the scene chain head, avail index, execbuffer, and response.
// A second store keeps the first. The descriptor bytes are not kept.
// This is not g6lc_apu_vgpu_avail.

// SceneChainGuestKeep (nxk): The head, the execbuffer, the response, and the avail index.
module g6lc_apu_vgpu_nxk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_sfc_t sfc_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_nxk_cpl_t cpl_o,
  output apu_vgpu_nxk_t nxk_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign nxk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|nxc_i) | (|sfc_i) | (|fet_i) | (|iwr_i) | (|qdr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_nxk_cpl_t cpl_q;
    apu_vgpu_nxk_t nxk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_nxk_cpl_t'('0);
    assign nxk_o = nxk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        nxk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (nxk_q.valid) begin
            cpl_q.status <= APU_VGPU_NXK_FAULT;
          end else if (!nxc_i.valid || !sfc_i.valid || !fet_i.valid ||
                       !iwr_i.valid || !qdr_i.valid) begin
            cpl_q.status <= APU_VGPU_NXK_EMPTY;
          end else if (nxc_i.head != 16'd0 || nxc_i.avail_idx != 16'd1 ||
                       nxc_i.buf_len != APU_VGPU_SCENE_BYTES ||
                       nxc_i.buf_addr != APU_VGPU_EXEC_ADDR ||
                       nxc_i.rsp_addr != APU_VGPU_RSP_ADDR ||
                       nxc_i.head == nxc_i.avail_idx ||
                       nxc_i.buf_addr == nxc_i.rsp_addr ||
                       sfc_i.hdr != APU_VIRGL_SF_HDR ||
                       sfc_i.handle != APU_VIRGL_SURFACE_HANDLE ||
                       sfc_i.resource != APU_VIRGL_RES_RT ||
                       32'(nxc_i.head) == sfc_i.handle ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS ||
                       iwr_i.resource != APU_VIRGL_RES_VBO ||
                       iwr_i.nbytes != APU_VIRGL_VBO_BYTES ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE) begin
            cpl_q.status <= APU_VGPU_NXK_FAULT;
          end else begin
            nxk_q.valid <= 1'b1;
            nxk_q.head <= nxc_i.head;
            nxk_q.avail_idx <= nxc_i.avail_idx;
            nxk_q.buf_len <= nxc_i.buf_len;
            nxk_q.buf_addr <= nxc_i.buf_addr;
            nxk_q.rsp_addr <= nxc_i.rsp_addr;
            cpl_q.status <= APU_VGPU_NXK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(nxk_o));
    `endif
  end
endmodule

// SceneChainGuestKeep (nxk) enable-0 fixture: The head, the execbuffer, the response, and the avail index.
module g6lc_apu_vgpu_nxk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_nxc_t nxc_i,
  input  apu_vgpu_sfc_t sfc_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_iwr_t iwr_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_nxk_cpl_t cpl_o,
  output apu_vgpu_nxk_t nxk_o
);
  g6lc_apu_vgpu_nxk #(.Enable(Enable)) i_dut (.*);
endmodule
