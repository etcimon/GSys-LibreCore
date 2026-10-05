// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// First command word is the surface CREATE_OBJECT after the guest-rung
// walk consumed device index 1. Transfer dest and device index 0
// record nothing. A second store keeps the first.

// GuestExecCheck (gex): cmd0 is CREATE_OBJECT after consumed device index 1.
module g6lc_apu_vgpu_gex
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gek_t gek_i,
  input  apu_vgpu_gef_t gef_i,
  input  apu_vgpu_gnx_t gnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gex_cpl_t cpl_o,
  output apu_vgpu_gex_t gex_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gex_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|gek_i) | (|gef_i) | (|gnx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gex_cpl_t cpl_q;
    apu_vgpu_gex_t gex_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gex_cpl_t'('0);
    assign gex_o = gex_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gex_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gex_q.valid) begin
            cpl_q.status <= APU_VGPU_GEX_FAULT;
          end else if (!gek_i.valid || !gef_i.valid || !gnx_i.valid) begin
            cpl_q.status <= APU_VGPU_GEX_EMPTY;
          end else if (gek_i.cmd0 != Cmd0 ||
                       gek_i.kind != VGPU_CMD_SUBMIT_3D ||
                       gek_i.device_idx != 16'd1 ||
                       gef_i.cmd0 != Cmd0 ||
                       gnx_i.device_idx != 16'd1 ||
                       gnx_i.buf_addr != APU_VGPU_EXEC_ADDR) begin
            cpl_q.status <= APU_VGPU_GEX_FAULT;
          end else begin
            gex_q.valid <= 1'b1;
            gex_q.cmd0 <= gek_i.cmd0;
            gex_q.device_idx <= 16'd1;
            cpl_q.status <= APU_VGPU_GEX_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_GEX_OK |->
        gex_o.valid && gex_o.cmd0 == Cmd0 && gex_o.device_idx == 16'd1);
    `endif
  end
endmodule

// GuestExecCheck (gex) enable-0 fixture: cmd0 is CREATE_OBJECT after consumed device index 1.
module g6lc_apu_vgpu_gex_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gek_t gek_i,
  input  apu_vgpu_gef_t gef_i,
  input  apu_vgpu_gnx_t gnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gex_cpl_t cpl_o,
  output apu_vgpu_gex_t gex_o
);
  g6lc_apu_vgpu_gex #(.Enable(Enable)) i_dut (.*);
endmodule
