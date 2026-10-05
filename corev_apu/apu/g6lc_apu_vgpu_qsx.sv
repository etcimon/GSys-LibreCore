// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Scene avail index 1 at 64'h8800E200 after QueueNotify of queue 0.
// The transfer index 2 and the transfer ring record nothing. A
// second store keeps the first. This is later than
// g6lc_apu_vgpu_qsk. This is not g6lc_apu_vgpu_qax and not
// g6lc_apu_vgpu_avail. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// SceneAvailIdxCheck (qsx): Scene index 1 at 64'h8800E200.
module g6lc_apu_vgpu_qsx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qsk_t qsk_i,
  input  apu_vgpu_qsv_t qsv_i,
  input  apu_vgpu_qay_t qay_i,
  input  apu_vgpu_qnx_t qnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsx_cpl_t cpl_o,
  output apu_vgpu_qsx_t qsx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qsx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qsk_i) | (|qsv_i) | (|qay_i) | (|qnx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qsx_cpl_t cpl_q;
    apu_vgpu_qsx_t qsx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qsx_cpl_t'('0);
    assign qsx_o = qsx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qsx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qsx_q.valid) begin
            cpl_q.status <= APU_VGPU_QSX_FAULT;
          end else if (!qsk_i.valid || !qsv_i.valid || !qay_i.valid ||
                       !qnx_i.valid) begin
            cpl_q.status <= APU_VGPU_QSX_EMPTY;
          end else if (qsk_i.avail_idx != APU_VGPU_QSV_IDXV ||
                       qsk_i.avail_idx == APU_VGPU_TUW_IDXV ||
                       qsk_i.addr != APU_VGPU_QSV_ADDR ||
                       qsk_i.addr == APU_VGPU_QAV_ADDR ||
                       qsk_i.avail_idx != qsv_i.avail_idx ||
                       qay_i.used_idx != APU_VGPU_TUW_IDXV ||
                       qnx_i.qid != APU_VGPU_QNT_QUEUE ||
                       qnx_i.qid == APU_VGPU_QNT_CURSOR ||
                       qnx_i.avail_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_QSX_FAULT;
          end else begin
            qsx_q.valid <= 1'b1;
            qsx_q.avail_idx <= qsk_i.avail_idx;
            cpl_q.status <= APU_VGPU_QSX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qsx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QSX_OK |->
        qsx_o.valid && qsx_o.avail_idx == APU_VGPU_QSV_IDXV);
    `endif
  end
endmodule

// SceneAvailIdxCheck (qsx) enable-0 fixture: Scene index 1 at 64'h8800E200.
module g6lc_apu_vgpu_qsx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qsk_t qsk_i,
  input  apu_vgpu_qsv_t qsv_i,
  input  apu_vgpu_qay_t qay_i,
  input  apu_vgpu_qnx_t qnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsx_cpl_t cpl_o,
  output apu_vgpu_qsx_t qsx_o
);
  g6lc_apu_vgpu_qsx #(.Enable(Enable)) i_dut (.*);
endmodule
