// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Fence 2 of the 64 by 64 transfer. The scene fence
// 64'h1122334455667788 records nothing. A missing fence bit
// records nothing. This is later than g6lc_apu_vgpu_rfr. This is
// not g6lc_apu_vgpu_gck. TEX is not the compiler opcode. This is
// not Mesa glReadPixels.

// TransferFenceCheck (rfx): Fence 2, not the scene fence.
module g6lc_apu_vgpu_rfx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rfr_t rfr_i,
  input  apu_vgpu_rfw_t rfw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rfx_cpl_t cpl_o,
  output apu_vgpu_rfx_t rfx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign rfx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rfr_i) | (|rfw_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_rfx_cpl_t cpl_q;
    apu_vgpu_rfx_t rfx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rfx_cpl_t'('0);
    assign rfx_o = rfx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rfx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rfx_q.valid) begin
            cpl_q.status <= APU_VGPU_RFX_FAULT;
          end else if (!rfr_i.valid || !rfw_i.valid) begin
            cpl_q.status <= APU_VGPU_RFX_EMPTY;
          end else if (rfr_i.fence != APU_VGPU_RFW_FENCE ||
                       rfr_i.fence == APU_VGPU_SCENE_FENCE ||
                       rfr_i.flags != VGPU_FLAG_FENCE ||
                       rfr_i.resp != VGPU_RESP_OK_NODATA ||
                       rfr_i.addr != APU_VGPU_RFW_ADDR ||
                       rfr_i.addr == APU_VGPU_RSP_ADDR ||
                       rfr_i.fence != rfw_i.fence ||
                       rfr_i.resp != rfw_i.resp) begin
            cpl_q.status <= APU_VGPU_RFX_FAULT;
          end else begin
            rfx_q.valid <= 1'b1;
            rfx_q.fence <= rfr_i.fence;
            rfx_q.flags <= rfr_i.flags;
            rfx_q.resp <= rfr_i.resp;
            cpl_q.status <= APU_VGPU_RFX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(rfx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RFX_OK |->
        rfx_o.valid && rfx_o.fence == APU_VGPU_RFW_FENCE &&
        rfx_o.fence != APU_VGPU_SCENE_FENCE &&
        rfx_o.flags == VGPU_FLAG_FENCE);
    `endif
  end
endmodule

// TransferFenceCheck (rfx) enable-0 fixture: Fence 2, not the scene fence.
module g6lc_apu_vgpu_rfx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rfr_t rfr_i,
  input  apu_vgpu_rfw_t rfw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rfx_cpl_t cpl_o,
  output apu_vgpu_rfx_t rfx_o
);
  g6lc_apu_vgpu_rfx #(.Enable(Enable)) i_dut (.*);
endmodule
