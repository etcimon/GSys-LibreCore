// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the submit type and the first execbuffer word after the
// guest-rung walk consumed device index 1. The buffer is not here.
// A second store keeps the first.

// GuestExecKeep (gek): Kept submit type and first command after gnx.
module g6lc_apu_vgpu_gek
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gef_t gef_i,
  input  apu_vgpu_gnx_t gnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gek_cpl_t cpl_o,
  output apu_vgpu_gek_t gek_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gek_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|gef_i) | (|gnx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gek_cpl_t cpl_q;
    apu_vgpu_gek_t gek_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gek_cpl_t'('0);
    assign gek_o = gek_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gek_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gek_q.valid) begin
            cpl_q.status <= APU_VGPU_GEK_FAULT;
          end else if (!gef_i.valid || !gnx_i.valid) begin
            cpl_q.status <= APU_VGPU_GEK_EMPTY;
          end else if (gef_i.kind != VGPU_CMD_SUBMIT_3D ||
                       gef_i.cmd0 != Cmd0 ||
                       gef_i.beats != APU_VGPU_EXEC_BEATS ||
                       gef_i.device_idx != 16'd1 ||
                       gnx_i.device_idx != 16'd1 ||
                       gnx_i.avail_idx != 16'd1 ||
                       gnx_i.buf_addr != APU_VGPU_EXEC_ADDR) begin
            cpl_q.status <= APU_VGPU_GEK_FAULT;
          end else begin
            gek_q.valid <= 1'b1;
            gek_q.kind <= gef_i.kind;
            gek_q.cmd0 <= gef_i.cmd0;
            gek_q.device_idx <= 16'd1;
            cpl_q.status <= APU_VGPU_GEK_OK;
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
    `endif
  end
endmodule

// GuestExecKeep (gek) enable-0 fixture: Kept submit type and first command after gnx.
module g6lc_apu_vgpu_gek_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gef_t gef_i,
  input  apu_vgpu_gnx_t gnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gek_cpl_t cpl_o,
  output apu_vgpu_gek_t gek_o
);
  g6lc_apu_vgpu_gek #(.Enable(Enable)) i_dut (.*);
endmodule
