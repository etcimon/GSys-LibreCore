// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep scene virtq_avail.ring[0] naming descriptor 0 at
// 64'h8800E204. The transfer ring at 64'h880D0104 and a nonzero
// id record nothing. A second store keeps the first. This is
// later than g6lc_apu_vgpu_qsr. This is not g6lc_apu_vgpu_qrk
// and not g6lc_apu_vgpu_nxc. The compiler TEX opcode still
// returns -26. This is not Mesa glReadPixels.

// SceneAvailRingKeep (qsl): Guest keep of that scene ring name.
module g6lc_apu_vgpu_qsl
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qsr_t qsr_i,
  input  apu_vgpu_qsx_t qsx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsl_cpl_t cpl_o,
  output apu_vgpu_qsl_t qsl_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qsl_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qsr_i) | (|qsx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qsl_cpl_t cpl_q;
    apu_vgpu_qsl_t qsl_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qsl_cpl_t'('0);
    assign qsl_o = qsl_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qsl_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qsl_q.valid) begin
            cpl_q.status <= APU_VGPU_QSL_FAULT;
          end else if (!qsr_i.valid || !qsx_i.valid) begin
            cpl_q.status <= APU_VGPU_QSL_EMPTY;
          end else if (qsr_i.desc_id != APU_VGPU_QRG_DESC ||
                       qsr_i.desc_id == 16'd1 ||
                       qsr_i.addr != APU_VGPU_QSR_ADDR ||
                       qsr_i.addr == APU_VGPU_QRG_ADDR ||
                       qsr_i.addr == APU_VGPU_QSV_ADDR ||
                       qsx_i.avail_idx != APU_VGPU_QSV_IDXV) begin
            cpl_q.status <= APU_VGPU_QSL_FAULT;
          end else begin
            qsl_q.valid <= 1'b1;
            qsl_q.desc_id <= qsr_i.desc_id;
            qsl_q.addr <= qsr_i.addr;
            cpl_q.status <= APU_VGPU_QSL_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qsl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QSL_OK |->
        qsl_o.valid && qsl_o.desc_id == APU_VGPU_QRG_DESC &&
        qsl_o.addr != APU_VGPU_QRG_ADDR);
    `endif
  end
endmodule

// SceneAvailRingKeep (qsl) enable-0 fixture: Guest keep of that scene ring name.
module g6lc_apu_vgpu_qsl_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qsr_t qsr_i,
  input  apu_vgpu_qsx_t qsx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsl_cpl_t cpl_o,
  output apu_vgpu_qsl_t qsl_o
);
  g6lc_apu_vgpu_qsl #(.Enable(Enable)) i_dut (.*);
endmodule
