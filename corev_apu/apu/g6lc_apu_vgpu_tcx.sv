// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (63,63) is red, 8'h0D. A first byte of blue 8'h1A or of
// 8'hFF records nothing. A second store keeps the first.
// The shader is not run.

// ReadbackFarCornerCheck (tcx): Byte 0 of (63,63) is red, not blue.
module g6lc_apu_vgpu_tcx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tck_t tck_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tcx_cpl_t cpl_o,
  output apu_vgpu_tcx_t tcx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tcx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tck_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_tcx_cpl_t cpl_q;
    apu_vgpu_tcx_t tcx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tcx_cpl_t'('0);
    assign tcx_o = tcx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tcx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tcx_q.valid) begin
            cpl_q.status <= APU_VGPU_TCX_FAULT;
          end else if (!tck_i.valid) begin
            cpl_q.status <= APU_VGPU_TCX_EMPTY;
          end else if (tck_i.r != APU_VGPU_CLEAR_R ||
                       tck_i.g != APU_VGPU_CLEAR_G ||
                       tck_i.b != APU_VGPU_CLEAR_B ||
                       tck_i.a != APU_VGPU_CLEAR_A ||
                       tck_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       tck_i.offset != APU_VGPU_GOF_LAST ||
                       tck_i.x != 7'd63 || tck_i.y != 7'd63 ||
                       b0_i != APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_TCX_FAULT;
          end else begin
            tcx_q.valid <= 1'b1;
            tcx_q.format <= tck_i.format;
            tcx_q.offset <= tck_i.offset;
            tcx_q.x <= tck_i.x;
            tcx_q.y <= tck_i.y;
            tcx_q.b0 <= b0_i;
            tcx_q.r <= tck_i.r;
            tcx_q.g <= tck_i.g;
            tcx_q.b <= tck_i.b;
            tcx_q.a <= tck_i.a;
            cpl_q.status <= APU_VGPU_TCX_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_TCX_OK |->
        tcx_o.valid && tcx_o.b0 == APU_VGPU_CLEAR_R &&
        tcx_o.b0 != APU_VGPU_CLEAR_A && tcx_o.b0 != APU_VGPU_CLEAR_B &&
        tcx_o.offset == APU_VGPU_GOF_LAST &&
        tcx_o.x == 7'd63 && tcx_o.y == 7'd63);
    `endif
  end
endmodule

// ReadbackFarCornerCheck (tcx) enable-0 fixture: Byte 0 of (63,63) is red, not blue.
module g6lc_apu_vgpu_tcx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tck_t tck_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tcx_cpl_t cpl_o,
  output apu_vgpu_tcx_t tcx_o
);
  g6lc_apu_vgpu_tcx #(.Enable(Enable)) i_dut (.*);
endmodule
