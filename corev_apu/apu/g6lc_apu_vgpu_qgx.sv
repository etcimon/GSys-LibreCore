// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Ack 32'h1 and remain 0 with used.idx 1. The transfer ack at
// 64'h880C0010 and index 2 record nothing. This is later than
// g6lc_apu_vgpu_qgk. This is not g6lc_apu_vgpu_qay and not
// g6lc_apu_vgpu_vak. TEX is not the compiler opcode. This is not
// Mesa glReadPixels.

// SceneUsedAckCheck (qgx): Ack 32'h1 and remain 0 at 64'h8800E510.
module g6lc_apu_vgpu_qgx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qgk_t qgk_i,
  input  apu_vgpu_qga_t qga_i,
  input  apu_vgpu_qsm_t qsm_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qgx_cpl_t cpl_o,
  output apu_vgpu_qgx_t qgx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qgx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qgk_i) | (|qga_i) | (|qsm_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qgx_cpl_t cpl_q;
    apu_vgpu_qgx_t qgx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qgx_cpl_t'('0);
    assign qgx_o = qgx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qgx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qgx_q.valid) begin
            cpl_q.status <= APU_VGPU_QGX_FAULT;
          end else if (!qgk_i.valid || !qga_i.valid || !qsm_i.valid) begin
            cpl_q.status <= APU_VGPU_QGX_EMPTY;
          end else if (qgk_i.ack != APU_VGPU_QSI_REASON ||
                       qgk_i.remain != APU_VGPU_VAW_CLEAR ||
                       qgk_i.used_idx != APU_VGPU_QSU_IDXV ||
                       qgk_i.used_idx == APU_VGPU_TUW_IDXV ||
                       qgk_i.ack == qgk_i.remain ||
                       qgk_i.ack_addr != APU_VGPU_QGA_ADDR ||
                       qgk_i.ack_addr == APU_VGPU_TAW_ADDR ||
                       qgk_i.status_addr != APU_VGPU_QGA_STAT ||
                       qgk_i.ack != qga_i.ack ||
                       qgk_i.remain != qga_i.remain ||
                       qsm_i.used_idx != APU_VGPU_QSU_IDXV) begin
            cpl_q.status <= APU_VGPU_QGX_FAULT;
          end else begin
            qgx_q.valid <= 1'b1;
            qgx_q.ack <= qgk_i.ack;
            qgx_q.remain <= qgk_i.remain;
            qgx_q.used_idx <= qgk_i.used_idx;
            cpl_q.status <= APU_VGPU_QGX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qgx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QGX_OK |->
        qgx_o.valid && qgx_o.ack == APU_VGPU_QSI_REASON &&
        qgx_o.remain == APU_VGPU_VAW_CLEAR &&
        qgx_o.used_idx == APU_VGPU_QSU_IDXV);
    `endif
  end
endmodule

// SceneUsedAckCheck (qgx) enable-0 fixture: Ack 32'h1 and remain 0 at 64'h8800E510.
module g6lc_apu_vgpu_qgx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qgk_t qgk_i,
  input  apu_vgpu_qga_t qga_i,
  input  apu_vgpu_qsm_t qsm_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qgx_cpl_t cpl_o,
  output apu_vgpu_qgx_t qgx_o
);
  g6lc_apu_vgpu_qgx #(.Enable(Enable)) i_dut (.*);
endmodule
