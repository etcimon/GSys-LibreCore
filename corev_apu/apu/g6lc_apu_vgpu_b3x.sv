// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (24,0) is red, 8'h0D. A first byte of blue 8'h1A or of
// 8'hFF records nothing. A second store keeps the first.
// The shader is not run.

// ReadbackBeat3Check (b3x): Byte 0 of (24,0) is red, not blue.
module g6lc_apu_vgpu_b3x
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_b3k_t b3k_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b3x_cpl_t cpl_o,
  output apu_vgpu_b3x_t b3x_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign b3x_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|b3k_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_b3x_cpl_t cpl_q;
    apu_vgpu_b3x_t b3x_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_b3x_cpl_t'('0);
    assign b3x_o = b3x_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        b3x_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (b3x_q.valid) begin
            cpl_q.status <= APU_VGPU_B3X_FAULT;
          end else if (!b3k_i.valid) begin
            cpl_q.status <= APU_VGPU_B3X_EMPTY;
          end else if (b3k_i.r != APU_VGPU_CLEAR_R ||
                       b3k_i.g != APU_VGPU_CLEAR_G ||
                       b3k_i.b != APU_VGPU_CLEAR_B ||
                       b3k_i.a != APU_VGPU_CLEAR_A ||
                       b3k_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       b3k_i.off24 != APU_VGPU_B3R_AT24 ||
                       b3k_i.off31 != APU_VGPU_B3R_AT31 ||
                       b3k_i.x24 != 7'd24 || b3k_i.x31 != 7'd31 ||
                       b0_i != APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_B3X_FAULT;
          end else begin
            b3x_q.valid <= 1'b1;
            b3x_q.format <= b3k_i.format;
            b3x_q.off24 <= b3k_i.off24;
            b3x_q.off31 <= b3k_i.off31;
            b3x_q.x24 <= b3k_i.x24;
            b3x_q.x31 <= b3k_i.x31;
            b3x_q.b0 <= b0_i;
            b3x_q.r <= b3k_i.r;
            b3x_q.g <= b3k_i.g;
            b3x_q.b <= b3k_i.b;
            b3x_q.a <= b3k_i.a;
            cpl_q.status <= APU_VGPU_B3X_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_B3X_OK |->
        b3x_o.valid && b3x_o.b0 == APU_VGPU_CLEAR_R &&
        b3x_o.b0 != APU_VGPU_CLEAR_A && b3x_o.b0 != APU_VGPU_CLEAR_B &&
        b3x_o.off24 == APU_VGPU_B3R_AT24 &&
        b3x_o.off31 == APU_VGPU_B3R_AT31);
    `endif
  end
endmodule

// ReadbackBeat3Check (b3x) enable-0 fixture: Byte 0 of (24,0) is red, not blue.
module g6lc_apu_vgpu_b3x_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_b3k_t b3k_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b3x_cpl_t cpl_o,
  output apu_vgpu_b3x_t b3x_o
);
  g6lc_apu_vgpu_b3x #(.Enable(Enable)) i_dut (.*);
endmodule
