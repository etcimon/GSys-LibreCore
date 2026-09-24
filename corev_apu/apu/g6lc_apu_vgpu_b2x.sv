// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (16,0) is red, 8'h0D. A first byte of blue 8'h1A or of
// 8'hFF records nothing. A second store keeps the first.
// The shader is not run.

module g6lc_apu_vgpu_b2x
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_b2k_t b2k_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b2x_cpl_t cpl_o,
  output apu_vgpu_b2x_t b2x_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign b2x_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|b2k_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_b2x_cpl_t cpl_q;
    apu_vgpu_b2x_t b2x_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_b2x_cpl_t'('0);
    assign b2x_o = b2x_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        b2x_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (b2x_q.valid) begin
            cpl_q.status <= APU_VGPU_B2X_FAULT;
          end else if (!b2k_i.valid) begin
            cpl_q.status <= APU_VGPU_B2X_EMPTY;
          end else if (b2k_i.r != APU_VGPU_CLEAR_R ||
                       b2k_i.g != APU_VGPU_CLEAR_G ||
                       b2k_i.b != APU_VGPU_CLEAR_B ||
                       b2k_i.a != APU_VGPU_CLEAR_A ||
                       b2k_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       b2k_i.off16 != APU_VGPU_B2R_AT16 ||
                       b2k_i.off23 != APU_VGPU_B2R_AT23 ||
                       b2k_i.x16 != 7'd16 || b2k_i.x23 != 7'd23 ||
                       b0_i != APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_B2X_FAULT;
          end else begin
            b2x_q.valid <= 1'b1;
            b2x_q.format <= b2k_i.format;
            b2x_q.off16 <= b2k_i.off16;
            b2x_q.off23 <= b2k_i.off23;
            b2x_q.x16 <= b2k_i.x16;
            b2x_q.x23 <= b2k_i.x23;
            b2x_q.b0 <= b0_i;
            b2x_q.r <= b2k_i.r;
            b2x_q.g <= b2k_i.g;
            b2x_q.b <= b2k_i.b;
            b2x_q.a <= b2k_i.a;
            cpl_q.status <= APU_VGPU_B2X_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_B2X_OK |->
        b2x_o.valid && b2x_o.b0 == APU_VGPU_CLEAR_R &&
        b2x_o.b0 != APU_VGPU_CLEAR_A && b2x_o.b0 != APU_VGPU_CLEAR_B &&
        b2x_o.off16 == APU_VGPU_B2R_AT16 &&
        b2x_o.off23 == APU_VGPU_B2R_AT23);
    `endif
  end
endmodule

module g6lc_apu_vgpu_b2x_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_b2k_t b2k_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b2x_cpl_t cpl_o,
  output apu_vgpu_b2x_t b2x_o
);
  g6lc_apu_vgpu_b2x #(.Enable(Enable)) i_dut (.*);
endmodule
