// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the clear word, the source window, and the readback address.
// A second store keeps the first. The image is not kept.
// The shader is not run.

// ReadbackCopyKeep (gbk): The clear word, the source, and the readback address.
module g6lc_apu_vgpu_gbk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbr_t gbr_i,
  input  apu_vgpu_gbw_t gbw_i,
  input  apu_vgpu_wfr_t wfr_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbk_cpl_t cpl_o,
  output apu_vgpu_gbk_t gbk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gbk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|gbr_i) | (|gbw_i) | (|wfr_i) | (|gpk_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gbk_cpl_t cpl_q;
    apu_vgpu_gbk_t gbk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gbk_cpl_t'('0);
    assign gbk_o = gbk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gbk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gbk_q.valid) begin
            cpl_q.status <= APU_VGPU_GBK_FAULT;
          end else if (!gbr_i.valid || !gbw_i.valid || !wfr_i.valid ||
                       !gpk_i.valid) begin
            cpl_q.status <= APU_VGPU_GBK_EMPTY;
          end else if (gbr_i.word != gbw_i.word ||
                       gbr_i.word != wfr_i.word ||
                       gbr_i.word != gpk_i.word ||
                       gbr_i.word != APU_VGPU_CLEAR_WORD ||
                       gbr_i.first != APU_VGPU_GBW_ADDR ||
                       gbr_i.last != APU_VGPU_GBW_TAIL ||
                       gbw_i.src != APU_VGPU_GPW_ADDR ||
                       gbw_i.dst != gbr_i.first ||
                       gbw_i.beats != APU_VGPU_GPW_BEATS ||
                       gbw_i.src == gbw_i.dst) begin
            cpl_q.status <= APU_VGPU_GBK_FAULT;
          end else begin
            gbk_q.valid <= 1'b1;
            gbk_q.word <= gbr_i.word;
            gbk_q.beats <= gbw_i.beats;
            gbk_q.src <= gbw_i.src;
            gbk_q.dst <= gbw_i.dst;
            cpl_q.status <= APU_VGPU_GBK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(gbk_o));
    `endif
  end
endmodule

// ReadbackCopyKeep (gbk) enable-0 fixture: The clear word, the source, and the readback address.
module g6lc_apu_vgpu_gbk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbr_t gbr_i,
  input  apu_vgpu_gbw_t gbw_i,
  input  apu_vgpu_wfr_t wfr_i,
  input  apu_vgpu_gpk_t gpk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbk_cpl_t cpl_o,
  output apu_vgpu_gbk_t gbk_o
);
  g6lc_apu_vgpu_gbk #(.Enable(Enable)) i_dut (.*);
endmodule
