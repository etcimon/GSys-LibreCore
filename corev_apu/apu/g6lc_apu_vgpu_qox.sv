// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Fence 2 OK_NODATA at 64'h880A0000 after the guest WRITE. The
// scene fence and a missing fence bit record nothing. A second
// store keeps the first. This is later than g6lc_apu_vgpu_qol.
// This is not g6lc_apu_vgpu_rfx. The compiler TEX opcode still
// returns -26. This is not Mesa glReadPixels.

// TransferOkNodataCheck (qox): Fence 2 OK_NODATA at 64'h880A0000.
module g6lc_apu_vgpu_qox
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qol_t qol_i,
  input  apu_vgpu_qok_t qok_i,
  input  apu_vgpu_qwx_t qwx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qox_cpl_t cpl_o,
  output apu_vgpu_qox_t qox_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qox_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qol_i) | (|qok_i) | (|qwx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qox_cpl_t cpl_q;
    apu_vgpu_qox_t qox_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qox_cpl_t'('0);
    assign qox_o = qox_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qox_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qox_q.valid) begin
            cpl_q.status <= APU_VGPU_QOX_FAULT;
          end else if (!qol_i.valid || !qok_i.valid || !qwx_i.valid) begin
            cpl_q.status <= APU_VGPU_QOX_EMPTY;
          end else if (qol_i.fence != APU_VGPU_RFW_FENCE ||
                       qol_i.fence == APU_VGPU_SCENE_FENCE ||
                       qol_i.flg != VGPU_FLAG_FENCE ||
                       qol_i.resp != VGPU_RESP_OK_NODATA ||
                       qol_i.addr != APU_VGPU_RFW_ADDR ||
                       qol_i.addr == APU_VGPU_RSP_ADDR ||
                       qol_i.fence != qok_i.fence ||
                       qol_i.resp != qok_i.resp ||
                       qwx_i.rsp_addr != APU_VGPU_RFW_ADDR) begin
            cpl_q.status <= APU_VGPU_QOX_FAULT;
          end else begin
            qox_q.valid <= 1'b1;
            qox_q.fence <= qol_i.fence;
            qox_q.resp <= qol_i.resp;
            cpl_q.status <= APU_VGPU_QOX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qox_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QOX_OK |->
        qox_o.valid && qox_o.fence == APU_VGPU_RFW_FENCE &&
        qox_o.resp == VGPU_RESP_OK_NODATA);
    `endif
  end
endmodule

// TransferOkNodataCheck (qox) enable-0 fixture: Fence 2 OK_NODATA at 64'h880A0000.
module g6lc_apu_vgpu_qox_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qol_t qol_i,
  input  apu_vgpu_qok_t qok_i,
  input  apu_vgpu_qwx_t qwx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qox_cpl_t cpl_o,
  output apu_vgpu_qox_t qox_o
);
  g6lc_apu_vgpu_qox #(.Enable(Enable)) i_dut (.*);
endmodule
