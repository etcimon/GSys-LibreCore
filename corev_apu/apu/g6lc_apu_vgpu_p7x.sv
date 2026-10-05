// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (7,0) is red, 8'h0D. A first byte of blue 8'h1A or of
// 8'hFF records nothing. A second store keeps the first.
// The shader is not run.

// ReadbackX7Check (p7x): Byte 0 of (7,0) is red, not blue.
module g6lc_apu_vgpu_p7x
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_p7k_t p7k_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_p7x_cpl_t cpl_o,
  output apu_vgpu_p7x_t p7x_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign p7x_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|p7k_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_p7x_cpl_t cpl_q;
    apu_vgpu_p7x_t p7x_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_p7x_cpl_t'('0);
    assign p7x_o = p7x_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        p7x_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (p7x_q.valid) begin
            cpl_q.status <= APU_VGPU_P7X_FAULT;
          end else if (!p7k_i.valid) begin
            cpl_q.status <= APU_VGPU_P7X_EMPTY;
          end else if (p7k_i.r != APU_VGPU_CLEAR_R ||
                       p7k_i.g != APU_VGPU_CLEAR_G ||
                       p7k_i.b != APU_VGPU_CLEAR_B ||
                       p7k_i.a != APU_VGPU_CLEAR_A ||
                       p7k_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       p7k_i.offset != APU_VGPU_P7R_AT ||
                       p7k_i.x != 7'd7 || p7k_i.y != 7'd0 ||
                       b0_i != APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_P7X_FAULT;
          end else begin
            p7x_q.valid <= 1'b1;
            p7x_q.format <= p7k_i.format;
            p7x_q.offset <= p7k_i.offset;
            p7x_q.x <= p7k_i.x;
            p7x_q.y <= p7k_i.y;
            p7x_q.b0 <= b0_i;
            p7x_q.r <= p7k_i.r;
            p7x_q.g <= p7k_i.g;
            p7x_q.b <= p7k_i.b;
            p7x_q.a <= p7k_i.a;
            cpl_q.status <= APU_VGPU_P7X_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_P7X_OK |->
        p7x_o.valid && p7x_o.b0 == APU_VGPU_CLEAR_R &&
        p7x_o.b0 != APU_VGPU_CLEAR_A && p7x_o.b0 != APU_VGPU_CLEAR_B &&
        p7x_o.offset == APU_VGPU_P7R_AT &&
        p7x_o.x == 7'd7 && p7x_o.y == 7'd0);
    `endif
  end
endmodule

// ReadbackX7Check (p7x) enable-0 fixture: Byte 0 of (7,0) is red, not blue.
module g6lc_apu_vgpu_p7x_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_p7k_t p7k_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_p7x_cpl_t cpl_o,
  output apu_vgpu_p7x_t p7x_o
);
  g6lc_apu_vgpu_p7x #(.Enable(Enable)) i_dut (.*);
endmodule
