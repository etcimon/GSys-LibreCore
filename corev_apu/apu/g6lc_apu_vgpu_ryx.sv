// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of row 1 is red, 8'h0D. A first byte of blue 8'h1A or of
// 8'hFF records nothing. A second store keeps the first.
// The shader is not run.

// ReadbackRow1Check (ryx): Byte 0 of row 1 is red, not blue.
module g6lc_apu_vgpu_ryx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ryk_t ryk_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ryx_cpl_t cpl_o,
  output apu_vgpu_ryx_t ryx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign ryx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|ryk_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_ryx_cpl_t cpl_q;
    apu_vgpu_ryx_t ryx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_ryx_cpl_t'('0);
    assign ryx_o = ryx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        ryx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (ryx_q.valid) begin
            cpl_q.status <= APU_VGPU_RYX_FAULT;
          end else if (!ryk_i.valid) begin
            cpl_q.status <= APU_VGPU_RYX_EMPTY;
          end else if (ryk_i.r != APU_VGPU_CLEAR_R ||
                       ryk_i.g != APU_VGPU_CLEAR_G ||
                       ryk_i.b != APU_VGPU_CLEAR_B ||
                       ryk_i.a != APU_VGPU_CLEAR_A ||
                       ryk_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       b0_i != APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_RYX_FAULT;
          end else begin
            ryx_q.valid <= 1'b1;
            ryx_q.format <= ryk_i.format;
            ryx_q.b0 <= b0_i;
            ryx_q.r <= ryk_i.r;
            ryx_q.g <= ryk_i.g;
            ryx_q.b <= ryk_i.b;
            ryx_q.a <= ryk_i.a;
            cpl_q.status <= APU_VGPU_RYX_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_RYX_OK |->
        ryx_o.valid && ryx_o.b0 == APU_VGPU_CLEAR_R &&
        ryx_o.b0 != APU_VGPU_CLEAR_A && ryx_o.b0 != APU_VGPU_CLEAR_B &&
        ryx_o.format == APU_VIRGL_FMT_B8G8R8X8);
    `endif
  end
endmodule

// ReadbackRow1Check (ryx) enable-0 fixture: Byte 0 of row 1 is red, not blue.
module g6lc_apu_vgpu_ryx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ryk_t ryk_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ryx_cpl_t cpl_o,
  output apu_vgpu_ryx_t ryx_o
);
  g6lc_apu_vgpu_ryx #(.Enable(Enable)) i_dut (.*);
endmodule
