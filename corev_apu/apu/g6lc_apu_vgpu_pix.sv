// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Four corner samples of the clear color inside the 64 by 64 ceiling.
// The draw must already be the four-vertex strip, the scissor 640 by 480,
// and the framebuffer surface 1. The interior is not written. The
// triangle is not walked.

module g6lc_apu_vgpu_pix
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_u8_t u8_i,
  input  apu_vgpu_sci_t sci_i,
  input  apu_vgpu_fbo_t fbo_i,
  input  apu_vgpu_drw_t drw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_pix_cpl_t cpl_o,
  output apu_vgpu_pix_t pix_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign pix_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|u8_i) | (|sci_i) | (|fbo_i) | (|drw_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_pix_cpl_t cpl_q;
    apu_vgpu_pix_t pix_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_pix_cpl_t'('0);
    assign pix_o = pix_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        pix_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic place;
          place = u8_i.word == APU_VGPU_CLEAR_WORD &&
                  sci_i.width == 16'(APU_VGPU_RT_W) && sci_i.height == 16'(APU_VGPU_RT_H) &&
                  fbo_i.nr_cbufs == 32'd1 && fbo_i.surface == APU_VIRGL_SURFACE_HANDLE &&
                  drw_i.count == APU_VIRGL_VERT_COUNT && drw_i.prim == APU_VIRGL_PRIM_STRIP &&
                  drw_i.next == APU_VGPU_SCENE_BYTES;
          if (pix_q.valid) begin
            cpl_q.status <= APU_VGPU_PIX_FAULT;
          end else if (!u8_i.valid || !sci_i.valid || !fbo_i.valid || !drw_i.valid) begin
            cpl_q.status <= APU_VGPU_PIX_EMPTY;
          end else if (!place) begin
            cpl_q.status <= APU_VGPU_PIX_FAULT;
          end else begin
            pix_q.valid <= 1'b1;
            pix_q.word <= u8_i.word;
            pix_q.a00 <= APU_VGPU_PIX_00;
            pix_q.ax <= APU_VGPU_PIX_X;
            pix_q.ay <= APU_VGPU_PIX_Y;
            pix_q.axy <= APU_VGPU_PIX_XY;
            cpl_q.status <= APU_VGPU_PIX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(pix_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_PIX_OK |->
        pix_o.valid && pix_o.word == APU_VGPU_CLEAR_WORD &&
        pix_o.a00 == APU_VGPU_PIX_00 && pix_o.axy == APU_VGPU_PIX_XY);
    `endif
  end
endmodule

module g6lc_apu_vgpu_pix_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_u8_t u8_i,
  input  apu_vgpu_sci_t sci_i,
  input  apu_vgpu_fbo_t fbo_i,
  input  apu_vgpu_drw_t drw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_pix_cpl_t cpl_o,
  output apu_vgpu_pix_t pix_o
);
  g6lc_apu_vgpu_pix #(.Enable(Enable)) i_dut (.*);
endmodule
