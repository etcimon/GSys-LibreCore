// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the origin texel and the blended neighbor at x = 1.
// The origin must match the corner store. The neighbor is the half blend.

// LinearBlendKeep (lnr): Origin texel and the blended neighbor.
module g6lc_apu_vgpu_lnr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_lin_t lin_i,
  input  apu_vgpu_bcp_t bcp_i,
  input  apu_vgpu_pxc_t pxc_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_lnr_cpl_t cpl_o,
  output apu_vgpu_lnr_t lnr_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign lnr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|lin_i) | (|bcp_i) | (|pxc_i);
  end else begin : gen_on
    typedef enum logic [1:0] { Idle, Done } state_e;
    typedef enum logic [1:0] { Need0, Need1, Full } phase_e;
    state_e state_q;
    phase_e phase_q;
    apu_vgpu_lnr_cpl_t cpl_q;
    apu_vgpu_lnr_t lnr_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_lnr_cpl_t'('0);
    assign lnr_o = lnr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        phase_q <= Need0;
        cpl_q <= '0;
        lnr_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (!lin_i.valid || !bcp_i.valid || !pxc_i.valid) begin
            cpl_q.status <= APU_VGPU_LNR_EMPTY;
          end else if (phase_q == Need0 && lin_i.x == 3'd0 &&
                       lin_i.word == bcp_i.word && lin_i.word == pxc_i.word) begin
            lnr_q.origin <= lin_i.word;
            cpl_q.status <= APU_VGPU_LNR_OK;
            phase_q <= Need1;
          end else if (phase_q == Need1 && lin_i.x == 3'd1) begin
            lnr_q.neighbor <= lin_i.word;
            lnr_q.valid <= 1'b1;
            cpl_q.status <= APU_VGPU_LNR_OK;
            phase_q <= Full;
          end else begin
            cpl_q.status <= APU_VGPU_LNR_FAULT;
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
      lnr_o.valid |-> lnr_o.origin == pxc_i.word);
    `endif
  end
endmodule

// LinearBlendKeep (lnr) enable-0 fixture: Origin texel and the blended neighbor.
module g6lc_apu_vgpu_lnr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_lin_t lin_i,
  input  apu_vgpu_bcp_t bcp_i,
  input  apu_vgpu_pxc_t pxc_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_lnr_cpl_t cpl_o,
  output apu_vgpu_lnr_t lnr_o
);
  g6lc_apu_vgpu_lnr #(.Enable(Enable)) i_dut (.*);
endmodule
