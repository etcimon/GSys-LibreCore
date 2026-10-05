// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// The clear word covers every sample of the 64 by 64 ceiling. The four
// corners are already stored, and the scissor is 640 by 480, which
// contains that ceiling. One word stands for all 4096 samples. The
// triangle is not walked.

// ClearCeilingFill (fil): The clear word covers the 64 by 64 ceiling.
module g6lc_apu_vgpu_fil
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_pix_t pix_i,
  input  apu_vgpu_sci_t sci_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_fil_cpl_t cpl_o,
  output apu_vgpu_fil_t fil_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign fil_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | (|pix_i) | (|sci_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_fil_cpl_t cpl_q;
    apu_vgpu_fil_t fil_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_fil_cpl_t'('0);
    assign fil_o = fil_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        fil_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          logic corners;
          corners = pix_i.word == APU_VGPU_CLEAR_WORD && pix_i.a00 == APU_VGPU_PIX_00 &&
                    pix_i.ax == APU_VGPU_PIX_X && pix_i.ay == APU_VGPU_PIX_Y &&
                    pix_i.axy == APU_VGPU_PIX_XY &&
                    sci_i.width == 16'd640 && sci_i.height == 16'd480;
          if (fil_q.valid) begin
            cpl_q.status <= APU_VGPU_FIL_FAULT;
          end else if (!pix_i.valid || !sci_i.valid) begin
            cpl_q.status <= APU_VGPU_FIL_EMPTY;
          end else if (!corners) begin
            cpl_q.status <= APU_VGPU_FIL_FAULT;
          end else begin
            fil_q.valid <= 1'b1;
            fil_q.word <= pix_i.word;
            fil_q.samples <= APU_VGPU_FILL_N;
            cpl_q.status <= APU_VGPU_FIL_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(fil_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_FIL_OK |->
        fil_o.valid && fil_o.word == APU_VGPU_CLEAR_WORD &&
        fil_o.samples == APU_VGPU_FILL_N);
    `endif
  end
endmodule

// ClearCeilingFill (fil) enable-0 fixture: The clear word covers the 64 by 64 ceiling.
module g6lc_apu_vgpu_fil_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_pix_t pix_i,
  input  apu_vgpu_sci_t sci_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_fil_cpl_t cpl_o,
  output apu_vgpu_fil_t fil_o
);
  g6lc_apu_vgpu_fil #(.Enable(Enable)) i_dut (.*);
endmodule
