// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// refused is 0. The held word is the clamp texel or the half
// blend, not the clear word. A refused sample records nothing.
// A second store keeps the first. This is later than
// g6lc_apu_vgpu_wlr. This is not g6lc_apu_vgpu_dnr. The compiler
// TEX opcode still returns -26. This is not Mesa glReadPixels.

// CoveredTexSampleCheck (wlk): refused 0 held word is clamp or half blend.
module g6lc_apu_vgpu_wlk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_wlr_t wlr_i,
  input  apu_vgpu_wld_t wld_i,
  input  apu_vgpu_hcx_t hcx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_wlk_cpl_t cpl_o,
  output apu_vgpu_wlk_t wlk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign wlk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|wlr_i) | (|wld_i) | (|hcx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_wlk_cpl_t cpl_q;
    apu_vgpu_wlk_t wlk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_wlk_cpl_t'('0);
    assign wlk_o = wlk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        wlk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (wlk_q.valid) begin
            cpl_q.status <= APU_VGPU_WLK_FAULT;
          end else if (!wlr_i.valid || !wld_i.valid || !hcx_i.valid) begin
            cpl_q.status <= APU_VGPU_WLK_EMPTY;
          end else if (wlr_i.refused == 1'b1 ||
                       wlr_i.word == APU_VGPU_CLEAR_WORD ||
                       wlr_i.word[7:0] == APU_VGPU_CLEAR_R ||
                       wlr_i.word != wld_i.word ||
                       wlr_i.addr != wld_i.addr ||
                       (wlr_i.word != hcx_i.origin &&
                        wlr_i.word != hcx_i.neighbor)) begin
            cpl_q.status <= APU_VGPU_WLK_FAULT;
          end else begin
            wlk_q.valid <= 1'b1;
            wlk_q.refused <= 1'b0;
            wlk_q.word <= wlr_i.word;
            wlk_q.addr <= wlr_i.addr;
            cpl_q.status <= APU_VGPU_WLK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(wlk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_WLK_OK |->
        wlk_o.valid && wlk_o.refused == 1'b0 &&
        wlk_o.word != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// CoveredTexSampleCheck (wlk) enable-0 fixture: refused 0 held word is clamp or half blend.
module g6lc_apu_vgpu_wlk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_wlr_t wlr_i,
  input  apu_vgpu_wld_t wld_i,
  input  apu_vgpu_hcx_t hcx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_wlk_cpl_t cpl_o,
  output apu_vgpu_wlk_t wlk_o
);
  g6lc_apu_vgpu_wlk #(.Enable(Enable)) i_dut (.*);
endmodule
