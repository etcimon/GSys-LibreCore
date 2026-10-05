// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Control queue 0 after avail index 2. The cursor queue and the
// scene index 1 record nothing. A second store keeps the first.
// This is later than g6lc_apu_vgpu_qnr. This is not
// g6lc_apu_virtio_mmio. The compiler TEX opcode still returns
// -26. This is not Mesa glReadPixels.

// TransferQueueNotifyCheck (qnx): Control queue 0 after avail index 2.
module g6lc_apu_vgpu_qnx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qnr_t qnr_i,
  input  apu_vgpu_qnt_t qnt_i,
  input  apu_vgpu_tnx_t tnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qnx_cpl_t cpl_o,
  output apu_vgpu_qnx_t qnx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qnx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qnr_i) | (|qnt_i) | (|tnx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qnx_cpl_t cpl_q;
    apu_vgpu_qnx_t qnx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qnx_cpl_t'('0);
    assign qnx_o = qnx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qnx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qnx_q.valid) begin
            cpl_q.status <= APU_VGPU_QNX_FAULT;
          end else if (!qnr_i.valid || !qnt_i.valid || !tnx_i.valid) begin
            cpl_q.status <= APU_VGPU_QNX_EMPTY;
          end else if (qnr_i.qid != APU_VGPU_QNT_QUEUE ||
                       qnr_i.qid == APU_VGPU_QNT_CURSOR ||
                       qnr_i.avail_idx != APU_VGPU_TUW_IDXV ||
                       qnr_i.avail_idx == 16'd1 ||
                       qnr_i.addr != APU_VGPU_QNT_ADDR ||
                       qnr_i.qid != qnt_i.qid ||
                       tnx_i.avail_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_QNX_FAULT;
          end else begin
            qnx_q.valid <= 1'b1;
            qnx_q.qid <= qnr_i.qid;
            qnx_q.avail_idx <= qnr_i.avail_idx;
            cpl_q.status <= APU_VGPU_QNX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qnx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QNX_OK |->
        qnx_o.valid && qnx_o.qid == APU_VGPU_QNT_QUEUE &&
        qnx_o.avail_idx == APU_VGPU_TUW_IDXV);
    `endif
  end
endmodule

// TransferQueueNotifyCheck (qnx) enable-0 fixture: Control queue 0 after avail index 2.
module g6lc_apu_vgpu_qnx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qnr_t qnr_i,
  input  apu_vgpu_qnt_t qnt_i,
  input  apu_vgpu_tnx_t tnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qnx_cpl_t cpl_o,
  output apu_vgpu_qnx_t qnx_o
);
  g6lc_apu_vgpu_qnx #(.Enable(Enable)) i_dut (.*);
endmodule
