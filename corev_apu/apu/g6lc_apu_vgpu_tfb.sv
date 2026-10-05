// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// TRANSFER_FROM_HOST_3D box (0,0,64,64) of resource 4 at 640 by
// 480. A 640 by 480 box records nothing. A 64 by 64 resource
// records nothing. This is later than g6lc_apu_vgpu_rox. The
// image is not kept. TEX is not the compiler opcode. This is not
// Mesa glReadPixels.

// TransferBox (tfb): TRANSFER_FROM_HOST_3D box (0,0,64,64) of the 640 by 480 target.
module g6lc_apu_vgpu_tfb
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rpw_t rpw_i,
  input  apu_vgpu_rox_t rox_i,
  input  apu_vgpu_grd_t grd_i,
  input  apu_vgpu_c3d_t c3d_i,
  input  logic [15:0] want_x_i,
  input  logic [15:0] want_y_i,
  input  logic [15:0] want_w_i,
  input  logic [15:0] want_h_i,
  input  logic [31:0] res_w_i,
  input  logic [31:0] res_h_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tfb_cpl_t cpl_o,
  output apu_vgpu_tfb_t tfb_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tfb_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|rpw_i) | (|rox_i) | (|grd_i) | (|c3d_i) |
                        (|want_x_i) | (|want_y_i) | (|want_w_i) | (|want_h_i) |
                        (|res_w_i) | (|res_h_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_tfb_cpl_t cpl_q;
    apu_vgpu_tfb_t tfb_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tfb_cpl_t'('0);
    assign tfb_o = tfb_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tfb_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tfb_q.valid) begin
            cpl_q.status <= APU_VGPU_TFB_FAULT;
          end else if (!rpw_i.valid || !rox_i.valid || !grd_i.valid ||
                       !c3d_i.rt_valid) begin
            cpl_q.status <= APU_VGPU_TFB_EMPTY;
          end else if (rpw_i.dst != APU_VGPU_RPW_DST ||
                       rpw_i.src != APU_VGPU_CSW_DST ||
                       rpw_i.cmd != VGPU_CMD_TRANSFER_FROM_HOST_3D ||
                       rpw_i.resource_id != APU_VIRGL_RES_RT ||
                       grd_i.base != APU_VGPU_RPW_DST ||
                       grd_i.cmd != VGPU_CMD_TRANSFER_FROM_HOST_3D ||
                       grd_i.width != APU_VGPU_GBD_W ||
                       grd_i.height != APU_VGPU_GBD_H ||
                       rox_i.x != 7'd0 || rox_i.y != 7'd0 ||
                       rox_i.word == APU_VGPU_CLEAR_WORD ||
                       rox_i.b0 == APU_VGPU_CLEAR_R ||
                       c3d_i.rt_w != APU_VGPU_RT_W ||
                       c3d_i.rt_h != APU_VGPU_RT_H ||
                       res_w_i != APU_VGPU_RT_W ||
                       res_h_i != APU_VGPU_RT_H ||
                       want_x_i != 16'd0 || want_y_i != 16'd0 ||
                       want_w_i != APU_VGPU_GBD_W ||
                       want_h_i != APU_VGPU_GBD_H) begin
            cpl_q.status <= APU_VGPU_TFB_FAULT;
          end else begin
            tfb_q.valid <= 1'b1;
            tfb_q.x <= 16'd0;
            tfb_q.y <= 16'd0;
            tfb_q.width <= APU_VGPU_GBD_W;
            tfb_q.height <= APU_VGPU_GBD_H;
            tfb_q.res_w <= APU_VGPU_RT_W;
            tfb_q.res_h <= APU_VGPU_RT_H;
            tfb_q.cmd <= VGPU_CMD_TRANSFER_FROM_HOST_3D;
            tfb_q.resource_id <= APU_VIRGL_RES_RT;
            cpl_q.status <= APU_VGPU_TFB_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(tfb_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_TFB_OK |->
        tfb_o.valid && tfb_o.x == 16'd0 && tfb_o.y == 16'd0 &&
        tfb_o.width == APU_VGPU_GBD_W && tfb_o.height == APU_VGPU_GBD_H &&
        tfb_o.res_w == APU_VGPU_RT_W && tfb_o.res_h == APU_VGPU_RT_H &&
        tfb_o.cmd == VGPU_CMD_TRANSFER_FROM_HOST_3D);
    `endif
  end
endmodule

// TransferBox (tfb) enable-0 fixture: TRANSFER_FROM_HOST_3D box (0,0,64,64) of the 640 by 480 target.
module g6lc_apu_vgpu_tfb_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_rpw_t rpw_i,
  input  apu_vgpu_rox_t rox_i,
  input  apu_vgpu_grd_t grd_i,
  input  apu_vgpu_c3d_t c3d_i,
  input  logic [15:0] want_x_i,
  input  logic [15:0] want_y_i,
  input  logic [15:0] want_w_i,
  input  logic [15:0] want_h_i,
  input  logic [31:0] res_w_i,
  input  logic [31:0] res_h_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tfb_cpl_t cpl_o,
  output apu_vgpu_tfb_t tfb_o
);
  g6lc_apu_vgpu_tfb #(.Enable(Enable)) i_dut (.*);
endmodule
