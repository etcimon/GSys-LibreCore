// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the two y = 2 samples. x = 0 first, then x = 1. Each word must
// differ from the y = 1 sample at that column.

module g6lc_apu_vgpu_y2r
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_y2b_t y2b_i,
  input  apu_vgpu_vlr_t vlr_i,
  input  apu_vgpu_vsx_t vsx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_y2r_cpl_t cpl_o,
  output apu_vgpu_y2r_t y2r_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign y2r_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|y2b_i) | (|vlr_i) | (|vsx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    typedef enum logic [1:0] { Need0, Need1, Full } phase_e;
    state_e state_q;
    phase_e phase_q;
    apu_vgpu_y2r_cpl_t cpl_q;
    apu_vgpu_y2r_t y2r_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_y2r_cpl_t'('0);
    assign y2r_o = y2r_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        phase_q <= Need0;
        cpl_q <= '0;
        y2r_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (!y2b_i.valid || !vlr_i.valid || !vsx_i.valid) begin
            cpl_q.status <= APU_VGPU_Y2R_EMPTY;
          end else if (phase_q == Need0 && y2b_i.x == 3'd0 &&
                       y2b_i.word != vlr_i.at0) begin
            y2r_q.at0 <= y2b_i.word;
            cpl_q.status <= APU_VGPU_Y2R_OK;
            phase_q <= Need1;
          end else if (phase_q == Need1 && y2b_i.x == 3'd1 &&
                       y2b_i.word != vlr_i.at1) begin
            y2r_q.at1 <= y2b_i.word;
            y2r_q.valid <= 1'b1;
            cpl_q.status <= APU_VGPU_Y2R_OK;
            phase_q <= Full;
          end else begin
            cpl_q.status <= APU_VGPU_Y2R_FAULT;
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
    `endif
  end
endmodule

module g6lc_apu_vgpu_y2r_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_y2b_t y2b_i,
  input  apu_vgpu_vlr_t vlr_i,
  input  apu_vgpu_vsx_t vsx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_y2r_cpl_t cpl_o,
  output apu_vgpu_y2r_t y2r_o
);
  g6lc_apu_vgpu_y2r #(.Enable(Enable)) i_dut (.*);
endmodule
