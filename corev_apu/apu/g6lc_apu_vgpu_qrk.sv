// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep virtq_avail.ring[0] naming descriptor 0 at 64'h880D0104.
// The scene ring at 64'h8800E204 and a nonzero id record nothing.
// A second store keeps the first. This is later than
// g6lc_apu_vgpu_qrg. This is not g6lc_apu_vgpu_txc. The compiler
// TEX opcode still returns -26. This is not Mesa glReadPixels.

// TransferAvailRingKeep (qrk): Keep that ring name.
module g6lc_apu_vgpu_qrk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qrg_t qrg_i,
  input  apu_vgpu_qax_t qax_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qrk_cpl_t cpl_o,
  output apu_vgpu_qrk_t qrk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qrk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qrg_i) | (|qax_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qrk_cpl_t cpl_q;
    apu_vgpu_qrk_t qrk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qrk_cpl_t'('0);
    assign qrk_o = qrk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qrk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qrk_q.valid) begin
            cpl_q.status <= APU_VGPU_QRK_FAULT;
          end else if (!qrg_i.valid || !qax_i.valid) begin
            cpl_q.status <= APU_VGPU_QRK_EMPTY;
          end else if (qrg_i.desc_id != APU_VGPU_QRG_DESC ||
                       qrg_i.desc_id == 16'd1 ||
                       qrg_i.addr != APU_VGPU_QRG_ADDR ||
                       qrg_i.addr == APU_VGPU_QRG_SCENE ||
                       qrg_i.addr == APU_VGPU_QAV_ADDR ||
                       qax_i.avail_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_QRK_FAULT;
          end else begin
            qrk_q.valid <= 1'b1;
            qrk_q.desc_id <= qrg_i.desc_id;
            qrk_q.addr <= qrg_i.addr;
            cpl_q.status <= APU_VGPU_QRK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qrk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QRK_OK |->
        qrk_o.valid && qrk_o.desc_id == APU_VGPU_QRG_DESC &&
        qrk_o.addr != APU_VGPU_QRG_SCENE);
    `endif
  end
endmodule

// TransferAvailRingKeep (qrk) enable-0 fixture: Keep that ring name.
module g6lc_apu_vgpu_qrk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qrg_t qrg_i,
  input  apu_vgpu_qax_t qax_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qrk_cpl_t cpl_o,
  output apu_vgpu_qrk_t qrk_o
);
  g6lc_apu_vgpu_qrk #(.Enable(Enable)) i_dut (.*);
endmodule
