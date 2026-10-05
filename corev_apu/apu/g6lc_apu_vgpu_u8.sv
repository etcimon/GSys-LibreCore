// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// The frozen clear floats become RGBA8 bytes. 0.05 is 13, 0.10 is 26,
// and 1.0 is 255, round half up. Byte 0 is red. Another red word
// records nothing. This is not a general float converter and it does
// not store a pixel.

// ClearToRgba8 (u8): Clear floats to RGBA8 bytes. Default-off. Not a general converter.
module g6lc_apu_vgpu_u8
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_clr_t clr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_u8_cpl_t cpl_o,
  output apu_vgpu_u8_t u8_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign u8_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|clr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_u8_cpl_t cpl_q;
    apu_vgpu_u8_t u8_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_u8_cpl_t'('0);
    assign u8_o = u8_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        u8_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (u8_q.valid) begin
            cpl_q.status <= APU_VGPU_U8_FAULT;
          end else if (!clr_i.valid) begin
            cpl_q.status <= APU_VGPU_U8_EMPTY;
          end else if (clr_i.buffers != APU_VIRGL_CLEAR_COLOR || clr_i.red != APU_VIRGL_F32_P05 ||
                       clr_i.green != APU_VIRGL_F32_P05 || clr_i.blue != APU_VIRGL_F32_P10 ||
                       clr_i.alpha != APU_VIRGL_F32_ONE || clr_i.next != 32'd908) begin
            cpl_q.status <= APU_VGPU_U8_FAULT;
          end else begin
            u8_q.valid <= 1'b1;
            u8_q.red <= APU_VGPU_CLEAR_R;
            u8_q.green <= APU_VGPU_CLEAR_G;
            u8_q.blue <= APU_VGPU_CLEAR_B;
            u8_q.alpha <= APU_VGPU_CLEAR_A;
            u8_q.word <= APU_VGPU_CLEAR_WORD;
            cpl_q.status <= APU_VGPU_U8_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(u8_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_U8_OK |->
        u8_o.valid && u8_o.word == APU_VGPU_CLEAR_WORD &&
        u8_o.word[7:0] == APU_VGPU_CLEAR_R && u8_o.word[31:24] == APU_VGPU_CLEAR_A);
    `endif
  end
endmodule

// ClearToRgba8 (u8) enable-0 fixture: Clear floats to RGBA8 bytes. Default-off. Not a general converter.
module g6lc_apu_vgpu_u8_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_clr_t clr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_u8_cpl_t cpl_o,
  output apu_vgpu_u8_t u8_o
);
  g6lc_apu_vgpu_u8 #(.Enable(Enable)) i_dut (.*);
endmodule
