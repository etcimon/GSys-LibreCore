// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep virtq_avail.idx 2 at 64'h880D0100. The scene ring at
// 64'h8800E200 and index 1 record nothing. A second store keeps
// the first. This is later than g6lc_apu_vgpu_qav. This is not
// g6lc_apu_vgpu_txc. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// TransferAvailIdxKeep (qak): Keep that avail.idx.
module g6lc_apu_vgpu_qak
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qav_t qav_i,
  input  apu_vgpu_qnx_t qnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qak_cpl_t cpl_o,
  output apu_vgpu_qak_t qak_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qak_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qav_i) | (|qnx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qak_cpl_t cpl_q;
    apu_vgpu_qak_t qak_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qak_cpl_t'('0);
    assign qak_o = qak_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qak_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qak_q.valid) begin
            cpl_q.status <= APU_VGPU_QAK_FAULT;
          end else if (!qav_i.valid || !qnx_i.valid) begin
            cpl_q.status <= APU_VGPU_QAK_EMPTY;
          end else if (qav_i.avail_idx != APU_VGPU_TUW_IDXV ||
                       qav_i.avail_idx == 16'd1 ||
                       qav_i.addr != APU_VGPU_QAV_ADDR ||
                       qav_i.addr == APU_VGPU_NXC_AVAIL ||
                       qnx_i.qid != APU_VGPU_QNT_QUEUE ||
                       qnx_i.avail_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_QAK_FAULT;
          end else begin
            qak_q.valid <= 1'b1;
            qak_q.avail_idx <= qav_i.avail_idx;
            qak_q.addr <= qav_i.addr;
            cpl_q.status <= APU_VGPU_QAK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qak_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QAK_OK |->
        qak_o.valid && qak_o.avail_idx == APU_VGPU_TUW_IDXV &&
        qak_o.addr != APU_VGPU_NXC_AVAIL);
    `endif
  end
endmodule

// TransferAvailIdxKeep (qak) enable-0 fixture: Keep that avail.idx.
module g6lc_apu_vgpu_qak_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qav_t qav_i,
  input  apu_vgpu_qnx_t qnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qak_cpl_t cpl_o,
  output apu_vgpu_qak_t qak_o
);
  g6lc_apu_vgpu_qak #(.Enable(Enable)) i_dut (.*);
endmodule
