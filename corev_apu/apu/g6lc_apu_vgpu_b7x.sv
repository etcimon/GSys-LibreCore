// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (56,0) is red, 8'h0D. A first byte of blue 8'h1A or of
// 8'hFF records nothing. A second store keeps the first.
// The shader is not run.

// ReadbackBeat7Check (b7x): Byte 0 of (56,0) is red, not blue.
module g6lc_apu_vgpu_b7x
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_b7k_t b7k_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b7x_cpl_t cpl_o,
  output apu_vgpu_b7x_t b7x_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign b7x_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|b7k_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_b7x_cpl_t cpl_q;
    apu_vgpu_b7x_t b7x_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_b7x_cpl_t'('0);
    assign b7x_o = b7x_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        b7x_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (b7x_q.valid) begin
            cpl_q.status <= APU_VGPU_B7X_FAULT;
          end else if (!b7k_i.valid) begin
            cpl_q.status <= APU_VGPU_B7X_EMPTY;
          end else if (b7k_i.r != APU_VGPU_CLEAR_R ||
                       b7k_i.g != APU_VGPU_CLEAR_G ||
                       b7k_i.b != APU_VGPU_CLEAR_B ||
                       b7k_i.a != APU_VGPU_CLEAR_A ||
                       b7k_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       b7k_i.off56 != APU_VGPU_B7R_AT56 ||
                       b7k_i.off63 != APU_VGPU_X6R_AT ||
                       b7k_i.x56 != 7'd56 || b7k_i.x63 != 7'd63 ||
                       b0_i != APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_B7X_FAULT;
          end else begin
            b7x_q.valid <= 1'b1;
            b7x_q.format <= b7k_i.format;
            b7x_q.off56 <= b7k_i.off56;
            b7x_q.off63 <= b7k_i.off63;
            b7x_q.x56 <= b7k_i.x56;
            b7x_q.x63 <= b7k_i.x63;
            b7x_q.b0 <= b0_i;
            b7x_q.r <= b7k_i.r;
            b7x_q.g <= b7k_i.g;
            b7x_q.b <= b7k_i.b;
            b7x_q.a <= b7k_i.a;
            cpl_q.status <= APU_VGPU_B7X_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_B7X_OK |->
        b7x_o.valid && b7x_o.b0 == APU_VGPU_CLEAR_R &&
        b7x_o.b0 != APU_VGPU_CLEAR_A && b7x_o.b0 != APU_VGPU_CLEAR_B &&
        b7x_o.off56 == APU_VGPU_B7R_AT56 &&
        b7x_o.off63 == APU_VGPU_X6R_AT);
    `endif
  end
endmodule

// ReadbackBeat7Check (b7x) enable-0 fixture: Byte 0 of (56,0) is red, not blue.
module g6lc_apu_vgpu_b7x_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_b7k_t b7k_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b7x_cpl_t cpl_o,
  output apu_vgpu_b7x_t b7x_o
);
  g6lc_apu_vgpu_b7x #(.Enable(Enable)) i_dut (.*);
endmodule
