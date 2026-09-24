// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (0,63) is red, 8'h0D. A first byte of blue 8'h1A or of
// 8'hFF records nothing. A second store keeps the first.
// The shader is not run.

module g6lc_apu_vgpu_tpx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tpk_t tpk_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tpx_cpl_t cpl_o,
  output apu_vgpu_tpx_t tpx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tpx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tpk_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_tpx_cpl_t cpl_q;
    apu_vgpu_tpx_t tpx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tpx_cpl_t'('0);
    assign tpx_o = tpx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tpx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tpx_q.valid) begin
            cpl_q.status <= APU_VGPU_TPX_FAULT;
          end else if (!tpk_i.valid) begin
            cpl_q.status <= APU_VGPU_TPX_EMPTY;
          end else if (tpk_i.r != APU_VGPU_CLEAR_R ||
                       tpk_i.g != APU_VGPU_CLEAR_G ||
                       tpk_i.b != APU_VGPU_CLEAR_B ||
                       tpk_i.a != APU_VGPU_CLEAR_A ||
                       tpk_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       tpk_i.off11 != APU_VGPU_TPR_AT11 ||
                       tpk_i.off23 != APU_VGPU_TPR_AT23 ||
                       tpk_i.off063 != APU_VGPU_TPR_AT063 ||
                       b0_i != APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_TPX_FAULT;
          end else begin
            tpx_q.valid <= 1'b1;
            tpx_q.format <= tpk_i.format;
            tpx_q.off11 <= tpk_i.off11;
            tpx_q.off23 <= tpk_i.off23;
            tpx_q.off063 <= tpk_i.off063;
            tpx_q.b0 <= b0_i;
            tpx_q.r <= tpk_i.r;
            tpx_q.g <= tpk_i.g;
            tpx_q.b <= tpk_i.b;
            tpx_q.a <= tpk_i.a;
            cpl_q.status <= APU_VGPU_TPX_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_TPX_OK |->
        tpx_o.valid && tpx_o.b0 == APU_VGPU_CLEAR_R &&
        tpx_o.b0 != APU_VGPU_CLEAR_A && tpx_o.b0 != APU_VGPU_CLEAR_B &&
        tpx_o.off11 == APU_VGPU_TPR_AT11 &&
        tpx_o.off23 == APU_VGPU_TPR_AT23 &&
        tpx_o.off063 == APU_VGPU_TPR_AT063);
    `endif
  end
endmodule

module g6lc_apu_vgpu_tpx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tpk_t tpk_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tpx_cpl_t cpl_o,
  output apu_vgpu_tpx_t tpx_o
);
  g6lc_apu_vgpu_tpx #(.Enable(Enable)) i_dut (.*);
endmodule
