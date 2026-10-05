// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// The guest readback buffer is a 64 by 64 rectangle, format
// B8G8R8X8, 16384 bytes, stride 256. A 640 by 480 request records
// nothing. The image is not kept. This is not Mesa glReadPixels.
// The shader is not run.

// ReadbackRect (gbd): 64 by 64 readback rectangle.
module g6lc_apu_vgpu_gbd
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbk_t gbk_i,
  input  logic [15:0] want_w_i,
  input  logic [15:0] want_h_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbd_cpl_t cpl_o,
  output apu_vgpu_gbd_t gbd_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gbd_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|gbk_i) | (|want_w_i) | (|want_h_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gbd_cpl_t cpl_q;
    apu_vgpu_gbd_t gbd_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gbd_cpl_t'('0);
    assign gbd_o = gbd_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gbd_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gbd_q.valid) begin
            cpl_q.status <= APU_VGPU_GBD_FAULT;
          end else if (!gbk_i.valid) begin
            cpl_q.status <= APU_VGPU_GBD_EMPTY;
          end else if (gbk_i.word != APU_VGPU_CLEAR_WORD ||
                       gbk_i.beats != APU_VGPU_GPW_BEATS ||
                       gbk_i.src != APU_VGPU_GPW_ADDR ||
                       gbk_i.dst != APU_VGPU_GBW_ADDR ||
                       want_w_i != APU_VGPU_GBD_W ||
                       want_h_i != APU_VGPU_GBD_H) begin
            cpl_q.status <= APU_VGPU_GBD_FAULT;
          end else begin
            gbd_q.valid <= 1'b1;
            gbd_q.width <= APU_VGPU_GBD_W;
            gbd_q.height <= APU_VGPU_GBD_H;
            gbd_q.stride <= APU_VGPU_GBD_STRIDE;
            gbd_q.bytes <= APU_VGPU_GBD_BYTES;
            gbd_q.format <= APU_VIRGL_FMT_B8G8R8X8;
            gbd_q.base <= APU_VGPU_GBW_ADDR;
            cpl_q.status <= APU_VGPU_GBD_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(gbd_o));
    `endif
  end
endmodule

// ReadbackRect (gbd) enable-0 fixture: 64 by 64 readback rectangle.
module g6lc_apu_vgpu_gbd_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbk_t gbk_i,
  input  logic [15:0] want_w_i,
  input  logic [15:0] want_h_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbd_cpl_t cpl_o,
  output apu_vgpu_gbd_t gbd_o
);
  g6lc_apu_vgpu_gbd #(.Enable(Enable)) i_dut (.*);
endmodule
