// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the clear red, blue, and packed word. A second store keeps
// the first. This does not write a pixel.

// ClearColorReadKeep (cwk): The red, the blue, and the packed word.
module g6lc_apu_vgpu_cwk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cwk_cpl_t cpl_o,
  output apu_vgpu_cwk_t cwk_o
);
  localparam logic [31:0] Cmd0 = {APU_VIRGL_SURFACE_DWORDS, APU_VIRGL_OBJ_SURFACE,
                                  APU_VIRGL_CREATE_OBJECT};

  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign cwk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|cwr_i) | (|fet_i) | (|cxr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_cwk_cpl_t cpl_q;
    apu_vgpu_cwk_t cwk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_cwk_cpl_t'('0);
    assign cwk_o = cwk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        cwk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (cwk_q.valid) begin
            cpl_q.status <= APU_VGPU_CWK_FAULT;
          end else if (!cwr_i.valid || !fet_i.valid || !cxr_i.valid) begin
            cpl_q.status <= APU_VGPU_CWK_EMPTY;
          end else if (cwr_i.red != APU_VIRGL_F32_P05 ||
                       cwr_i.blue != APU_VIRGL_F32_P10 ||
                       cwr_i.word != APU_VGPU_CLEAR_WORD ||
                       cwr_i.red == cwr_i.blue ||
                       cwr_i.word == cwr_i.red ||
                       cxr_i.width != 16'd640 || cxr_i.height != 16'd480 ||
                       fet_i.kind != VGPU_CMD_SUBMIT_3D ||
                       fet_i.cmd0 != Cmd0 ||
                       fet_i.beats != APU_VGPU_EXEC_BEATS) begin
            cpl_q.status <= APU_VGPU_CWK_FAULT;
          end else begin
            cwk_q.valid <= 1'b1;
            cwk_q.red <= cwr_i.red;
            cwk_q.blue <= cwr_i.blue;
            cwk_q.word <= cwr_i.word;
            cpl_q.status <= APU_VGPU_CWK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(cwk_o));
    `endif
  end
endmodule

// ClearColorReadKeep (cwk) enable-0 fixture: The red, the blue, and the packed word.
module g6lc_apu_vgpu_cwk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_cwr_t cwr_i,
  input  apu_vgpu_fet_t fet_i,
  input  apu_vgpu_cxr_t cxr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_cwk_cpl_t cpl_o,
  output apu_vgpu_cwk_t cwk_o
);
  g6lc_apu_vgpu_cwk #(.Enable(Enable)) i_dut (.*);
endmodule
