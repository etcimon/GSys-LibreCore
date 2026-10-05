// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the color-buffer count, the surface handle, and the clear
// word. A second store keeps the first. This does not attach memory.

// FramebufferReadKeep (fbk): The color-buffer count, the surface, and the clear word.
module g6lc_apu_vgpu_fbk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fbr_t fbr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_fbk_cpl_t cpl_o,
  output apu_vgpu_fbk_t fbk_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign fbk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|fbr_i) | (|fet_i) | (|cwr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_fbk_cpl_t cpl_q;
    apu_vgpu_fbk_t fbk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_fbk_cpl_t'('0);
    assign fbk_o = fbk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        fbk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (fbk_q.valid) begin
            cpl_q.status <= APU_VGPU_FBK_FAULT;
          end else if (!fbr_i.valid || !fet_i.valid || !cwr_i.valid) begin
            cpl_q.status <= APU_VGPU_FBK_EMPTY;
          end else if (fbr_i.nr_cbufs != 32'd1 ||
                       fbr_i.surface != APU_VIRGL_SURFACE_HANDLE ||
                       fbr_i.word != APU_VGPU_CLEAR_WORD ||
                       fbr_i.word == fbr_i.surface ||
                       cwr_i.word != fbr_i.word ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS) begin
            cpl_q.status <= APU_VGPU_FBK_FAULT;
          end else begin
            fbk_q.valid <= 1'b1;
            fbk_q.nr_cbufs <= fbr_i.nr_cbufs;
            fbk_q.surface <= fbr_i.surface;
            fbk_q.word <= fbr_i.word;
            cpl_q.status <= APU_VGPU_FBK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(fbk_o));
    `endif
  end
endmodule

// FramebufferReadKeep (fbk) enable-0 fixture: The color-buffer count, the surface, and the clear word.
module g6lc_apu_vgpu_fbk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fbr_t fbr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_cwr_t cwr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_fbk_cpl_t cpl_o,
  output apu_vgpu_fbk_t fbk_o
);
  g6lc_apu_vgpu_fbk #(.Enable(Enable)) i_dut (.*);
endmodule
