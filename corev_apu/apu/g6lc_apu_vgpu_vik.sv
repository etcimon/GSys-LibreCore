// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the used-buffer interrupt reason and the used index. A second
// store keeps the first. The pin is not kept. The shader is not run.

// UsedIrqKeep (vik): The reason and the used index.
module g6lc_apu_vgpu_vik
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_vir_t vir_i,
  input  apu_vgpu_viw_t viw_i,
  input  apu_vgpu_gck_t gck_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_ols_t ols_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vik_cpl_t cpl_o,
  output apu_vgpu_vik_t vik_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vik_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|vir_i) | (|viw_i) | (|gck_i) | (|gpk_i) | (|ols_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_vik_cpl_t cpl_q;
    apu_vgpu_vik_t vik_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_vik_cpl_t'('0);
    assign vik_o = vik_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        vik_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (vik_q.valid) begin
            cpl_q.status <= APU_VGPU_VIK_FAULT;
          end else if (!vir_i.valid || !viw_i.valid || !gck_i.valid ||
                       !gpk_i.valid || !ols_i.valid) begin
            cpl_q.status <= APU_VGPU_VIK_EMPTY;
          end else if (vir_i.reason != viw_i.reason ||
                       vir_i.used_idx != viw_i.used_idx ||
                       vir_i.reason != APU_VGPU_VIW_REASON ||
                       vir_i.used_idx != 16'd1 ||
                       vir_i.used_idx != gck_i.used_idx ||
                       gck_i.resp != VGPU_RESP_OK_NODATA ||
                       gck_i.fence != APU_VGPU_SCENE_FENCE ||
                       gpk_i.word != APU_VGPU_CLEAR_WORD ||
                       gpk_i.last != APU_VGPU_GPW_TAIL ||
                       ols_i.count != 32'h0 || ols_i.capset_id != 32'h0 ||
                       ols_i.resp != VGPU_RESP_OK_NODATA) begin
            cpl_q.status <= APU_VGPU_VIK_FAULT;
          end else begin
            vik_q.valid <= 1'b1;
            vik_q.reason <= vir_i.reason;
            vik_q.used_idx <= vir_i.used_idx;
            cpl_q.status <= APU_VGPU_VIK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(vik_o));
    `endif
  end
endmodule

// UsedIrqKeep (vik) enable-0 fixture: The reason and the used index.
module g6lc_apu_vgpu_vik_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_vir_t vir_i,
  input  apu_vgpu_viw_t viw_i,
  input  apu_vgpu_gck_t gck_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  apu_vgpu_ols_t ols_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_vik_cpl_t cpl_o,
  output apu_vgpu_vik_t vik_o
);
  g6lc_apu_vgpu_vik #(.Enable(Enable)) i_dut (.*);
endmodule
