// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep that covered TEX sample after the guest transfer beat.
// refused stays 0. The clear word and a coordinate outside the
// pair record nothing. A second store keeps the first. This is
// later than g6lc_apu_vgpu_wld. This is not g6lc_apu_vgpu_hld.
// The compiler TEX opcode still returns -26. This is not Mesa
// glReadPixels.

// CoveredTexSampleKeep (wlr): Guest keep of that covered TEX sample.
module g6lc_apu_vgpu_wlr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_wld_t wld_i,
  input  apu_vgpu_hcx_t hcx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_wlr_cpl_t cpl_o,
  output apu_vgpu_wlr_t wlr_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign wlr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|wld_i) | (|hcx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_wlr_cpl_t cpl_q;
    apu_vgpu_wlr_t wlr_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_wlr_cpl_t'('0);
    assign wlr_o = wlr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        wlr_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (wlr_q.valid) begin
            cpl_q.status <= APU_VGPU_WLR_FAULT;
          end else if (!wld_i.valid || !hcx_i.valid) begin
            cpl_q.status <= APU_VGPU_WLR_EMPTY;
          end else if (wld_i.refused == 1'b1 ||
                       wld_i.word == APU_VGPU_CLEAR_WORD ||
                       ((wld_i.x != 7'd0 || wld_i.y != 7'd0) &&
                        (wld_i.x != 7'd1 || wld_i.y != 7'd0)) ||
                       (wld_i.x == 7'd0 && wld_i.word != hcx_i.origin) ||
                       (wld_i.x == 7'd1 && wld_i.word != hcx_i.neighbor)) begin
            cpl_q.status <= APU_VGPU_WLR_FAULT;
          end else begin
            wlr_q.valid <= 1'b1;
            wlr_q.refused <= 1'b0;
            wlr_q.word <= wld_i.word;
            wlr_q.addr <= wld_i.addr;
            wlr_q.x <= wld_i.x;
            wlr_q.y <= wld_i.y;
            cpl_q.status <= APU_VGPU_WLR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(wlr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_WLR_OK |->
        wlr_o.valid && wlr_o.refused == 1'b0 &&
        wlr_o.word != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// CoveredTexSampleKeep (wlr) enable-0 fixture: Guest keep of that covered TEX sample.
module g6lc_apu_vgpu_wlr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_wld_t wld_i,
  input  apu_vgpu_hcx_t hcx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_wlr_cpl_t cpl_o,
  output apu_vgpu_wlr_t wlr_o
);
  g6lc_apu_vgpu_wlr #(.Enable(Enable)) i_dut (.*);
endmodule
