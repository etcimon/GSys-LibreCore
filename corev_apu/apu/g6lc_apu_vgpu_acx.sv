// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Byte 0 of (1,0) is the sample red. A first byte of the clear
// red 8'h0D, of blue 8'h1A, or of 8'hFF records nothing. A second
// store keeps the first. This is later than g6lc_apu_vgpu_acr.
// The shader is not the compiler TEX opcode. This is not the
// screenshot.

// LinearPairCheck (acx): Byte 0 of (1,0) is the sample, not the clear.
module g6lc_apu_vgpu_acx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_acr_t acr_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_acx_cpl_t cpl_o,
  output apu_vgpu_acx_t acx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign acx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|acr_i) | (|b0_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_acx_cpl_t cpl_q;
    apu_vgpu_acx_t acx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_acx_cpl_t'('0);
    assign acx_o = acx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        acx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (acx_q.valid) begin
            cpl_q.status <= APU_VGPU_ACX_FAULT;
          end else if (!acr_i.valid) begin
            cpl_q.status <= APU_VGPU_ACX_EMPTY;
          end else if (acr_i.base != APU_VGPU_ACW_ADDR ||
                       acr_i.off0 != APU_VGPU_ACW_AT0 ||
                       acr_i.off1 != APU_VGPU_ACW_AT1 ||
                       acr_i.x0 != 7'd0 || acr_i.x1 != 7'd1 ||
                       acr_i.origin == APU_VGPU_CLEAR_WORD ||
                       acr_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       acr_i.origin == acr_i.neighbor ||
                       acr_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       b0_i != acr_i.neighbor[7:0] ||
                       b0_i == APU_VGPU_CLEAR_R ||
                       b0_i == APU_VGPU_CLEAR_B ||
                       b0_i == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_ACX_FAULT;
          end else begin
            acx_q.valid <= 1'b1;
            acx_q.format <= acr_i.format;
            acx_q.off0 <= acr_i.off0;
            acx_q.off1 <= acr_i.off1;
            acx_q.x0 <= acr_i.x0;
            acx_q.x1 <= acr_i.x1;
            acx_q.b0 <= b0_i;
            acx_q.origin <= acr_i.origin;
            acx_q.neighbor <= acr_i.neighbor;
            cpl_q.status <= APU_VGPU_ACX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(acx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_ACX_OK |->
        acx_o.valid && acx_o.b0 != APU_VGPU_CLEAR_R &&
        acx_o.b0 != APU_VGPU_CLEAR_A && acx_o.b0 != APU_VGPU_CLEAR_B &&
        acx_o.off1 == APU_VGPU_ACW_AT1 &&
        acx_o.neighbor != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// LinearPairCheck (acx) enable-0 fixture: Byte 0 of (1,0) is the sample, not the clear.
module g6lc_apu_vgpu_acx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_acr_t acr_i,
  input  logic [7:0] b0_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_acx_cpl_t cpl_o,
  output apu_vgpu_acx_t acx_o
);
  g6lc_apu_vgpu_acx #(.Enable(Enable)) i_dut (.*);
endmodule
