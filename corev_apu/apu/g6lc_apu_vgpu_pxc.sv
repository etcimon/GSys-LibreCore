// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Ceiling pixel (0,0) takes the corner texel. The record is that one
// word. Other ceiling samples are not written.

// CeilingOriginTexel (pxc): Ceiling (0,0) takes that texel. Default-off. Other samples stay clear.
module g6lc_apu_vgpu_pxc
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tap_t tap_i,
  input  apu_vgpu_bcp_t bcp_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_pxc_cpl_t cpl_o,
  output apu_vgpu_pxc_t pxc_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign pxc_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tap_i) | (|bcp_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_pxc_cpl_t cpl_q;
    apu_vgpu_pxc_t pxc_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_pxc_cpl_t'('0);
    assign pxc_o = pxc_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        pxc_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (pxc_q.valid) begin
            cpl_q.status <= APU_VGPU_PXC_FAULT;
          end else if (!tap_i.valid || !bcp_i.valid) begin
            cpl_q.status <= APU_VGPU_PXC_EMPTY;
          end else if (tap_i.x != 10'd0 || tap_i.y != 6'd0 ||
                       tap_i.word != bcp_i.word ||
                       bcp_i.beats != APU_VGPU_SCAN_BAND_BEATS ||
                       bcp_i.bytes != APU_VGPU_SCAN_BAND_BYTES) begin
            cpl_q.status <= APU_VGPU_PXC_FAULT;
          end else begin
            pxc_q.valid <= 1'b1;
            pxc_q.word <= tap_i.word;
            cpl_q.status <= APU_VGPU_PXC_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_PXC_OK |->
        pxc_o.valid && pxc_o.word == tap_i.word);
    `endif
  end
endmodule

// CeilingOriginTexel (pxc) enable-0 fixture: Ceiling (0,0) takes that texel. Default-off. Other samples stay clear.
module g6lc_apu_vgpu_pxc_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tap_t tap_i,
  input  apu_vgpu_bcp_t bcp_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_pxc_cpl_t cpl_o,
  output apu_vgpu_pxc_t pxc_o
);
  g6lc_apu_vgpu_pxc #(.Enable(Enable)) i_dut (.*);
endmodule
