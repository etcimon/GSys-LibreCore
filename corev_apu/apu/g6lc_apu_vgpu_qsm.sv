// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Reason 32'h1 at 64'h8800E500 with used.idx 1 after the scene
// used ring. The transfer status word at 64'h880C0000 records
// nothing. Index 2 records nothing. This is later than
// g6lc_apu_vgpu_qsn. This is not g6lc_apu_vgpu_qix and not
// g6lc_apu_vgpu_vik. The pin is not kept. TEX is not the compiler
// opcode. This is not Mesa glReadPixels.

// SceneUsedIrqCheck (qsm): Reason 32'h1 at 64'h8800E500.
module g6lc_apu_vgpu_qsm
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qsn_t qsn_i,
  input  apu_vgpu_qsi_t qsi_i,
  input  apu_vgpu_qsz_t qsz_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsm_cpl_t cpl_o,
  output apu_vgpu_qsm_t qsm_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qsm_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qsn_i) | (|qsi_i) | (|qsz_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qsm_cpl_t cpl_q;
    apu_vgpu_qsm_t qsm_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qsm_cpl_t'('0);
    assign qsm_o = qsm_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qsm_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qsm_q.valid) begin
            cpl_q.status <= APU_VGPU_QSM_FAULT;
          end else if (!qsn_i.valid || !qsi_i.valid || !qsz_i.valid) begin
            cpl_q.status <= APU_VGPU_QSM_EMPTY;
          end else if (qsn_i.reason != APU_VGPU_QSI_REASON ||
                       qsn_i.used_idx != APU_VGPU_QSU_IDXV ||
                       qsn_i.used_idx == APU_VGPU_TUW_IDXV ||
                       qsn_i.addr != APU_VGPU_QSI_ADDR ||
                       qsn_i.addr == APU_VGPU_TIW_ADDR ||
                       qsn_i.reason != qsi_i.reason ||
                       qsn_i.used_idx != qsi_i.used_idx ||
                       qsz_i.used_idx != APU_VGPU_QSU_IDXV) begin
            cpl_q.status <= APU_VGPU_QSM_FAULT;
          end else begin
            qsm_q.valid <= 1'b1;
            qsm_q.reason <= qsn_i.reason;
            qsm_q.used_idx <= qsn_i.used_idx;
            qsm_q.addr <= qsn_i.addr;
            cpl_q.status <= APU_VGPU_QSM_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qsm_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QSM_OK |->
        qsm_o.valid && qsm_o.reason == APU_VGPU_QSI_REASON &&
        qsm_o.used_idx == APU_VGPU_QSU_IDXV &&
        qsm_o.addr != APU_VGPU_TIW_ADDR);
    `endif
  end
endmodule

// SceneUsedIrqCheck (qsm) enable-0 fixture: Reason 32'h1 at 64'h8800E500.
module g6lc_apu_vgpu_qsm_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qsn_t qsn_i,
  input  apu_vgpu_qsi_t qsi_i,
  input  apu_vgpu_qsz_t qsz_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsm_cpl_t cpl_o,
  output apu_vgpu_qsm_t qsm_o
);
  g6lc_apu_vgpu_qsm #(.Enable(Enable)) i_dut (.*);
endmodule
