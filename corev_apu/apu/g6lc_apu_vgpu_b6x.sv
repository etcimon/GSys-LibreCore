// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (48,0) is red, 8'h0D. A first byte of blue 8'h1A or of
// 8'hFF records nothing. A second store keeps the first.
// The shader is not run.

// ReadbackBeat6Check (b6x): Byte 0 of (48,0) is red, not blue.
module g6lc_apu_vgpu_b6x
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_b6k_t b6k_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b6x_cpl_t cpl_o,
  output apu_vgpu_b6x_t b6x_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign b6x_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|b6k_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_b6x_cpl_t cpl_q;
    apu_vgpu_b6x_t b6x_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_b6x_cpl_t'('0);
    assign b6x_o = b6x_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        b6x_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (b6x_q.valid) begin
            cpl_q.status <= APU_VGPU_B6X_FAULT;
          end else if (!b6k_i.valid) begin
            cpl_q.status <= APU_VGPU_B6X_EMPTY;
          end else if (b6k_i.r != APU_VGPU_CLEAR_R ||
                       b6k_i.g != APU_VGPU_CLEAR_G ||
                       b6k_i.b != APU_VGPU_CLEAR_B ||
                       b6k_i.a != APU_VGPU_CLEAR_A ||
                       b6k_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       b6k_i.off48 != APU_VGPU_B6R_AT48 ||
                       b6k_i.off55 != APU_VGPU_B6R_AT55 ||
                       b6k_i.x48 != 7'd48 || b6k_i.x55 != 7'd55 ||
                       b0_i != APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_B6X_FAULT;
          end else begin
            b6x_q.valid <= 1'b1;
            b6x_q.format <= b6k_i.format;
            b6x_q.off48 <= b6k_i.off48;
            b6x_q.off55 <= b6k_i.off55;
            b6x_q.x48 <= b6k_i.x48;
            b6x_q.x55 <= b6k_i.x55;
            b6x_q.b0 <= b0_i;
            b6x_q.r <= b6k_i.r;
            b6x_q.g <= b6k_i.g;
            b6x_q.b <= b6k_i.b;
            b6x_q.a <= b6k_i.a;
            cpl_q.status <= APU_VGPU_B6X_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_B6X_OK |->
        b6x_o.valid && b6x_o.b0 == APU_VGPU_CLEAR_R &&
        b6x_o.b0 != APU_VGPU_CLEAR_A && b6x_o.b0 != APU_VGPU_CLEAR_B &&
        b6x_o.off48 == APU_VGPU_B6R_AT48 &&
        b6x_o.off55 == APU_VGPU_B6R_AT55);
    `endif
  end
endmodule

// ReadbackBeat6Check (b6x) enable-0 fixture: Byte 0 of (48,0) is red, not blue.
module g6lc_apu_vgpu_b6x_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_b6k_t b6k_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b6x_cpl_t cpl_o,
  output apu_vgpu_b6x_t b6x_o
);
  g6lc_apu_vgpu_b6x #(.Enable(Enable)) i_dut (.*);
endmodule
