// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// The guest TRANSFER_FROM_HOST_3D buffer is a 64 by 64 rectangle,
// format B8G8R8X8, 16384 bytes, stride 256, base 64'h88070000.
// A 640 by 480 request records nothing. This is later than
// g6lc_apu_vgpu_rpx. The image is not kept. TEX is not the
// compiler opcode. This is not Mesa glReadPixels.

// GuestReadpixelsRect (grd): 64 by 64 guest readpixels rectangle.
module g6lc_apu_vgpu_grd
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rpw_t rpw_i,
  input  apu_vgpu_rpx_t rpx_i,
  input  logic [15:0] want_w_i,
  input  logic [15:0] want_h_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_grd_cpl_t cpl_o,
  output apu_vgpu_grd_t grd_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign grd_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rpw_i) | (|rpx_i) | (|want_w_i) | (|want_h_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_grd_cpl_t cpl_q;
    apu_vgpu_grd_t grd_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_grd_cpl_t'('0);
    assign grd_o = grd_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        grd_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (grd_q.valid) begin
            cpl_q.status <= APU_VGPU_GRD_FAULT;
          end else if (!rpw_i.valid || !rpx_i.valid) begin
            cpl_q.status <= APU_VGPU_GRD_EMPTY;
          end else if (rpw_i.dst != APU_VGPU_RPW_DST ||
                       rpw_i.src != APU_VGPU_CSW_DST ||
                       rpw_i.beats != APU_VGPU_GPW_BEATS ||
                       rpw_i.cmd != VGPU_CMD_TRANSFER_FROM_HOST_3D ||
                       rpw_i.resource_id != APU_VIRGL_RES_RT ||
                       rpw_i.origin == APU_VGPU_CLEAR_WORD ||
                       rpw_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       rpw_i.origin == rpw_i.neighbor ||
                       rpx_i.origin != rpw_i.origin ||
                       rpx_i.neighbor != rpw_i.neighbor ||
                       rpx_i.b0 != rpx_i.neighbor[7:0] ||
                       rpx_i.b0 == APU_VGPU_CLEAR_R ||
                       rpx_i.x1 != 7'd1 ||
                       want_w_i != APU_VGPU_GBD_W ||
                       want_h_i != APU_VGPU_GBD_H) begin
            cpl_q.status <= APU_VGPU_GRD_FAULT;
          end else begin
            grd_q.valid <= 1'b1;
            grd_q.width <= APU_VGPU_GBD_W;
            grd_q.height <= APU_VGPU_GBD_H;
            grd_q.stride <= APU_VGPU_GBD_STRIDE;
            grd_q.bytes <= APU_VGPU_GBD_BYTES;
            grd_q.format <= APU_VIRGL_FMT_B8G8R8X8;
            grd_q.base <= APU_VGPU_RPW_DST;
            grd_q.origin <= rpw_i.origin;
            grd_q.neighbor <= rpw_i.neighbor;
            grd_q.cmd <= rpw_i.cmd;
            cpl_q.status <= APU_VGPU_GRD_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(grd_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_GRD_OK |->
        grd_o.valid && grd_o.base == APU_VGPU_RPW_DST &&
        grd_o.base != APU_VGPU_CSW_DST &&
        grd_o.cmd == VGPU_CMD_TRANSFER_FROM_HOST_3D &&
        grd_o.width == APU_VGPU_GBD_W && grd_o.height == APU_VGPU_GBD_H &&
        grd_o.neighbor != APU_VGPU_CLEAR_WORD &&
        grd_o.origin != grd_o.neighbor);
    `endif
  end
endmodule

// GuestReadpixelsRect (grd) enable-0 fixture: 64 by 64 guest readpixels rectangle.
module g6lc_apu_vgpu_grd_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rpw_t rpw_i,
  input  apu_vgpu_rpx_t rpx_i,
  input  logic [15:0] want_w_i,
  input  logic [15:0] want_h_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_grd_cpl_t cpl_o,
  output apu_vgpu_grd_t grd_o
);
  g6lc_apu_vgpu_grd #(.Enable(Enable)) i_dut (.*);
endmodule
