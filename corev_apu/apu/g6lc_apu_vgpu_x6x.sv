// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (63,0) is red, 8'h0D. A first byte of blue 8'h1A or of
// 8'hFF records nothing. A second store keeps the first.
// The shader is not run.

module g6lc_apu_vgpu_x6x
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_x6k_t x6k_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_x6x_cpl_t cpl_o,
  output apu_vgpu_x6x_t x6x_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign x6x_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|x6k_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_x6x_cpl_t cpl_q;
    apu_vgpu_x6x_t x6x_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_x6x_cpl_t'('0);
    assign x6x_o = x6x_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        x6x_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (x6x_q.valid) begin
            cpl_q.status <= APU_VGPU_X6X_FAULT;
          end else if (!x6k_i.valid) begin
            cpl_q.status <= APU_VGPU_X6X_EMPTY;
          end else if (x6k_i.r != APU_VGPU_CLEAR_R ||
                       x6k_i.g != APU_VGPU_CLEAR_G ||
                       x6k_i.b != APU_VGPU_CLEAR_B ||
                       x6k_i.a != APU_VGPU_CLEAR_A ||
                       x6k_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       x6k_i.offset != APU_VGPU_X6R_AT ||
                       x6k_i.x != 7'd63 || x6k_i.y != 7'd0 ||
                       b0_i != APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_X6X_FAULT;
          end else begin
            x6x_q.valid <= 1'b1;
            x6x_q.format <= x6k_i.format;
            x6x_q.offset <= x6k_i.offset;
            x6x_q.x <= x6k_i.x;
            x6x_q.y <= x6k_i.y;
            x6x_q.b0 <= b0_i;
            x6x_q.r <= x6k_i.r;
            x6x_q.g <= x6k_i.g;
            x6x_q.b <= x6k_i.b;
            x6x_q.a <= x6k_i.a;
            cpl_q.status <= APU_VGPU_X6X_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_X6X_OK |->
        x6x_o.valid && x6x_o.b0 == APU_VGPU_CLEAR_R &&
        x6x_o.b0 != APU_VGPU_CLEAR_A && x6x_o.b0 != APU_VGPU_CLEAR_B &&
        x6x_o.offset == APU_VGPU_X6R_AT &&
        x6x_o.x == 7'd63 && x6x_o.y == 7'd0);
    `endif
  end
endmodule

module g6lc_apu_vgpu_x6x_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_x6k_t x6k_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_x6x_cpl_t cpl_o,
  output apu_vgpu_x6x_t x6x_o
);
  g6lc_apu_vgpu_x6x #(.Enable(Enable)) i_dut (.*);
endmodule
