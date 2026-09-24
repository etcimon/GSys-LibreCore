// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the stride, the offset, and the resource. A second store
// keeps the first. This does not fetch vertices.

module g6lc_apu_vgpu_vbk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_vbf_t vbf_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vbk_cpl_t cpl_o,
  output apu_vgpu_vbk_t vbk_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vbk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|vbf_i) | (|fet_i) | (|qdr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_vbk_cpl_t cpl_q;
    apu_vgpu_vbk_t vbk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_vbk_cpl_t'('0);
    assign vbk_o = vbk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        vbk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (vbk_q.valid) begin
            cpl_q.status <= APU_VGPU_VBK_FAULT;
          end else if (!vbf_i.valid || !fet_i.valid || !qdr_i.valid) begin
            cpl_q.status <= APU_VGPU_VBK_EMPTY;
          end else if (vbf_i.stride != APU_VIRGL_VERT_STRIDE ||
                       vbf_i.offset != 32'h0 ||
                       vbf_i.resource != APU_VIRGL_RES_VBO ||
                       vbf_i.stride == vbf_i.resource ||
                       qdr_i.x0 != APU_VIRGL_F32_NEG_ONE ||
                       qdr_i.last != APU_VIRGL_F32_ONE ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS) begin
            cpl_q.status <= APU_VGPU_VBK_FAULT;
          end else begin
            vbk_q.valid <= 1'b1;
            vbk_q.stride <= vbf_i.stride;
            vbk_q.offset <= vbf_i.offset;
            vbk_q.resource <= vbf_i.resource;
            cpl_q.status <= APU_VGPU_VBK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(vbk_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_vbk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_vbf_t vbf_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_qdr_t qdr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vbk_cpl_t cpl_o,
  output apu_vgpu_vbk_t vbk_o
);
  g6lc_apu_vgpu_vbk #(.Enable(Enable)) i_dut (.*);
endmodule
