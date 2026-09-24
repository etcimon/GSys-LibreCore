// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the clear word and the first and last beat addresses of the
// 64 by 64 window. A second store keeps the first. The bytes are not
// kept. The shader is not run.

module g6lc_apu_vgpu_gpk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gpr_t gpr_i,
  input  apu_vgpu_gpw_t gpw_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_fet_t fet_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gpk_cpl_t cpl_o,
  output apu_vgpu_gpk_t gpk_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gpk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|gpr_i) | (|gpw_i) | (|cwr_i) | (|ols_i) | (|fet_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gpk_cpl_t cpl_q;
    apu_vgpu_gpk_t gpk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gpk_cpl_t'('0);
    assign gpk_o = gpk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gpk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gpk_q.valid) begin
            cpl_q.status <= APU_VGPU_GPK_FAULT;
          end else if (!gpr_i.valid || !gpw_i.valid || !cwr_i.valid ||
                       !ols_i.valid || !fet_i.valid) begin
            cpl_q.status <= APU_VGPU_GPK_EMPTY;
          end else if (gpr_i.word != APU_VGPU_CLEAR_WORD ||
                       gpr_i.first != APU_VGPU_GPW_ADDR ||
                       gpr_i.last != APU_VGPU_GPW_TAIL ||
                       gpr_i.first == gpr_i.last ||
                       gpr_i.word != gpw_i.word ||
                       gpr_i.word != cwr_i.word ||
                       gpw_i.beats != APU_VGPU_GPW_BEATS ||
                       gpw_i.base != APU_VGPU_GPW_ADDR ||
                       ols_i.count != 32'h0 || ols_i.capset_id != 32'h0 ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS) begin
            cpl_q.status <= APU_VGPU_GPK_FAULT;
          end else begin
            gpk_q.valid <= 1'b1;
            gpk_q.word <= gpr_i.word;
            gpk_q.first <= gpr_i.first;
            gpk_q.last <= gpr_i.last;
            cpl_q.status <= APU_VGPU_GPK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(gpk_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_gpk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gpr_t gpr_i,
  input  apu_vgpu_gpw_t gpw_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_ols_t ols_i,
  input  apu_vgpu_fet_t fet_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gpk_cpl_t cpl_o,
  output apu_vgpu_gpk_t gpk_o
);
  g6lc_apu_vgpu_gpk #(.Enable(Enable)) i_dut (.*);
endmodule
