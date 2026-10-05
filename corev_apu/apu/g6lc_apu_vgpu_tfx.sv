// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Packed stride of the 64 by 64 box is 256. The 640-wide resource
// row is 2560 and records nothing. A shifted origin records
// nothing. This is later than g6lc_apu_vgpu_tfr. TEX is not the
// compiler opcode. This is not Mesa glReadPixels.

// TransferBoxCheck (tfx): Packed stride 256 of that box, not the 640-wide resource row.
module g6lc_apu_vgpu_tfx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tfr_t tfr_i,
  input  apu_vgpu_tfb_t tfb_i,
  input  apu_vgpu_rox_t rox_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tfx_cpl_t cpl_o,
  output apu_vgpu_tfx_t tfx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tfx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tfr_i) | (|tfb_i) | (|rox_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_tfx_cpl_t cpl_q;
    apu_vgpu_tfx_t tfx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tfx_cpl_t'('0);
    assign tfx_o = tfx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tfx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tfx_q.valid) begin
            cpl_q.status <= APU_VGPU_TFX_FAULT;
          end else if (!tfr_i.valid || !tfb_i.valid || !rox_i.valid) begin
            cpl_q.status <= APU_VGPU_TFX_EMPTY;
          end else if (tfr_i.x != 16'd0 || tfr_i.y != 16'd0 ||
                       tfr_i.width != APU_VGPU_GBD_W ||
                       tfr_i.height != APU_VGPU_GBD_H ||
                       tfr_i.stride != APU_VGPU_TFB_STRIDE ||
                       tfr_i.stride == APU_VGPU_TFB_ROW ||
                       tfr_i.addr != APU_VGPU_TFB_CMD ||
                       tfr_i.cmd != VGPU_CMD_TRANSFER_FROM_HOST_3D ||
                       tfr_i.resource_id != APU_VIRGL_RES_RT ||
                       tfb_i.res_w != APU_VGPU_RT_W ||
                       tfb_i.res_h != APU_VGPU_RT_H ||
                       tfb_i.res_w == 32'(APU_VGPU_GBD_W) ||
                       rox_i.b0 == APU_VGPU_CLEAR_R ||
                       rox_i.word == APU_VGPU_CLEAR_WORD) begin
            cpl_q.status <= APU_VGPU_TFX_FAULT;
          end else begin
            tfx_q.valid <= 1'b1;
            tfx_q.stride <= tfr_i.stride;
            tfx_q.x <= tfr_i.x;
            tfx_q.y <= tfr_i.y;
            tfx_q.res_w <= tfb_i.res_w;
            cpl_q.status <= APU_VGPU_TFX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(tfx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_TFX_OK |->
        tfx_o.valid && tfx_o.stride == APU_VGPU_TFB_STRIDE &&
        tfx_o.x == 16'd0 && tfx_o.res_w == APU_VGPU_RT_W);
    `endif
  end
endmodule

// TransferBoxCheck (tfx) enable-0 fixture: Packed stride 256 of that box, not the 640-wide resource row.
module g6lc_apu_vgpu_tfx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tfr_t tfr_i,
  input  apu_vgpu_tfb_t tfb_i,
  input  apu_vgpu_rox_t rox_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tfx_cpl_t cpl_o,
  output apu_vgpu_tfx_t tfx_o
);
  g6lc_apu_vgpu_tfx #(.Enable(Enable)) i_dut (.*);
endmodule
