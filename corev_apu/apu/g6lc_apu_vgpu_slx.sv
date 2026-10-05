// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// used.idx 1 after the scene OK_NODATA. The transfer index 2 and
// descriptor id 1 record nothing. A second store keeps the
// first. This is later than g6lc_apu_vgpu_sll. This is not
// g6lc_apu_vgpu_qux and not g6lc_apu_vgpu_qsz. The compiler TEX
// opcode still returns -26. This is not Mesa glReadPixels.

// SceneUsedAfterNotifyCheck (slx): used.idx 1 after scene OK_NODATA.
module g6lc_apu_vgpu_slx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sll_t sll_i,
  input  apu_vgpu_slw_t slw_i,
  input  apu_vgpu_sox_t sox_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_slx_cpl_t cpl_o,
  output apu_vgpu_slx_t slx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign slx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|sll_i) | (|slw_i) | (|sox_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_slx_cpl_t cpl_q;
    apu_vgpu_slx_t slx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_slx_cpl_t'('0);
    assign slx_o = slx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        slx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (slx_q.valid) begin
            cpl_q.status <= APU_VGPU_SLX_FAULT;
          end else if (!sll_i.valid || !slw_i.valid || !sox_i.valid) begin
            cpl_q.status <= APU_VGPU_SLX_EMPTY;
          end else if (sll_i.used_idx != APU_VGPU_QSU_IDXV ||
                       sll_i.used_idx == APU_VGPU_TUW_IDXV ||
                       sll_i.elem_id != APU_VGPU_QSU_ID ||
                       sll_i.elem_id == APU_VGPU_TUW_ID ||
                       sll_i.elem_addr == APU_VGPU_TUW_ELEM ||
                       sll_i.used_idx != slw_i.used_idx ||
                       sll_i.elem_id != slw_i.elem_id ||
                       sox_i.fence != APU_VGPU_SCENE_FENCE) begin
            cpl_q.status <= APU_VGPU_SLX_FAULT;
          end else begin
            slx_q.valid <= 1'b1;
            slx_q.used_idx <= sll_i.used_idx;
            slx_q.elem_id <= sll_i.elem_id;
            cpl_q.status <= APU_VGPU_SLX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(slx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SLX_OK |->
        slx_o.valid && slx_o.used_idx == APU_VGPU_QSU_IDXV &&
        slx_o.elem_id == APU_VGPU_QSU_ID);
    `endif
  end
endmodule

// SceneUsedAfterNotifyCheck (slx) enable-0 fixture: used.idx 1 after scene OK_NODATA.
module g6lc_apu_vgpu_slx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sll_t sll_i,
  input  apu_vgpu_slw_t slw_i,
  input  apu_vgpu_sox_t sox_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_slx_cpl_t cpl_o,
  output apu_vgpu_slx_t slx_o
);
  g6lc_apu_vgpu_slx #(.Enable(Enable)) i_dut (.*);
endmodule
