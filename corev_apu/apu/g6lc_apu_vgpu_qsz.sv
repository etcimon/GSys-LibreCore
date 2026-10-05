// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// used.idx 1 after the scene OK_NODATA. The transfer index 2 and
// descriptor id 1 record nothing. A second store keeps the
// first. This is later than g6lc_apu_vgpu_qst. This is not
// g6lc_apu_vgpu_qux. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// SceneUsedWriteCheck (qsz): used.idx 1 at 64'h8800E480.
module g6lc_apu_vgpu_qsz
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qst_t qst_i,
  input  apu_vgpu_qsu_t qsu_i,
  input  apu_vgpu_qsq_t qsq_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsz_cpl_t cpl_o,
  output apu_vgpu_qsz_t qsz_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qsz_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qst_i) | (|qsu_i) | (|qsq_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qsz_cpl_t cpl_q;
    apu_vgpu_qsz_t qsz_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qsz_cpl_t'('0);
    assign qsz_o = qsz_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qsz_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qsz_q.valid) begin
            cpl_q.status <= APU_VGPU_QSZ_FAULT;
          end else if (!qst_i.valid || !qsu_i.valid || !qsq_i.valid) begin
            cpl_q.status <= APU_VGPU_QSZ_EMPTY;
          end else if (qst_i.used_idx != APU_VGPU_QSU_IDXV ||
                       qst_i.used_idx == APU_VGPU_TUW_IDXV ||
                       qst_i.elem_id != APU_VGPU_QSU_ID ||
                       qst_i.elem_id == APU_VGPU_TUW_ID ||
                       qst_i.elem_addr == APU_VGPU_TUW_ELEM ||
                       qst_i.used_idx != qsu_i.used_idx ||
                       qst_i.elem_id != qsu_i.elem_id ||
                       qsq_i.fence != APU_VGPU_SCENE_FENCE) begin
            cpl_q.status <= APU_VGPU_QSZ_FAULT;
          end else begin
            qsz_q.valid <= 1'b1;
            qsz_q.used_idx <= qst_i.used_idx;
            qsz_q.elem_id <= qst_i.elem_id;
            cpl_q.status <= APU_VGPU_QSZ_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qsz_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QSZ_OK |->
        qsz_o.valid && qsz_o.used_idx == APU_VGPU_QSU_IDXV &&
        qsz_o.elem_id == APU_VGPU_QSU_ID);
    `endif
  end
endmodule

// SceneUsedWriteCheck (qsz) enable-0 fixture: used.idx 1 at 64'h8800E480.
module g6lc_apu_vgpu_qsz_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qst_t qst_i,
  input  apu_vgpu_qsu_t qsu_i,
  input  apu_vgpu_qsq_t qsq_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsz_cpl_t cpl_o,
  output apu_vgpu_qsz_t qsz_o
);
  g6lc_apu_vgpu_qsz #(.Enable(Enable)) i_dut (.*);
endmodule
