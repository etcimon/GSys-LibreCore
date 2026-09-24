// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the three offsets and the clear channels. A second store
// keeps the first. The image is not kept. The shader is not run.

module g6lc_apu_vgpu_tpk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tpr_t tpr_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tpk_cpl_t cpl_o,
  output apu_vgpu_tpk_t tpk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tpk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tpr_i) | (|gbd_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_tpk_cpl_t cpl_q;
    apu_vgpu_tpk_t tpk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tpk_cpl_t'('0);
    assign tpk_o = tpk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tpk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tpk_q.valid) begin
            cpl_q.status <= APU_VGPU_TPK_FAULT;
          end else if (!tpr_i.valid || !gbd_i.valid) begin
            cpl_q.status <= APU_VGPU_TPK_EMPTY;
          end else if (tpr_i.r != APU_VGPU_CLEAR_R ||
                       tpr_i.g != APU_VGPU_CLEAR_G ||
                       tpr_i.b != APU_VGPU_CLEAR_B ||
                       tpr_i.a != APU_VGPU_CLEAR_A ||
                       {tpr_i.a, tpr_i.b, tpr_i.g, tpr_i.r} != APU_VGPU_CLEAR_WORD ||
                       tpr_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       tpr_i.off11 != APU_VGPU_TPR_AT11 ||
                       tpr_i.off23 != APU_VGPU_TPR_AT23 ||
                       tpr_i.off063 != APU_VGPU_TPR_AT063 ||
                       gbd_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       gbd_i.bytes != APU_VGPU_GBD_BYTES ||
                       gbd_i.base != APU_VGPU_GBW_ADDR) begin
            cpl_q.status <= APU_VGPU_TPK_FAULT;
          end else begin
            tpk_q.valid <= 1'b1;
            tpk_q.format <= tpr_i.format;
            tpk_q.off11 <= tpr_i.off11;
            tpk_q.off23 <= tpr_i.off23;
            tpk_q.off063 <= tpr_i.off063;
            tpk_q.r <= tpr_i.r;
            tpk_q.g <= tpr_i.g;
            tpk_q.b <= tpr_i.b;
            tpk_q.a <= tpr_i.a;
            cpl_q.status <= APU_VGPU_TPK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(tpk_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_tpk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tpr_t tpr_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tpk_cpl_t cpl_o,
  output apu_vgpu_tpk_t tpk_o
);
  g6lc_apu_vgpu_tpk #(.Enable(Enable)) i_dut (.*);
endmodule
