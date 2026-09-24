// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the x = 8 sample. The origin and the x = 1 blend stay put.

module g6lc_apu_vgpu_spx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_spn_t spn_i,
  input  apu_vgpu_lnr_t lnr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_spx_cpl_t cpl_o,
  output apu_vgpu_spx_t spx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign spx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|spn_i) | (|lnr_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_spx_cpl_t cpl_q;
    apu_vgpu_spx_t spx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_spx_cpl_t'('0);
    assign spx_o = spx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        spx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (spx_q.valid) begin
            cpl_q.status <= APU_VGPU_SPX_FAULT;
          end else if (!spn_i.valid || !lnr_i.valid) begin
            cpl_q.status <= APU_VGPU_SPX_EMPTY;
          end else if (spn_i.x != 4'd8 || lnr_i.origin == lnr_i.neighbor) begin
            cpl_q.status <= APU_VGPU_SPX_FAULT;
          end else begin
            spx_q.valid <= 1'b1;
            spx_q.word <= spn_i.word;
            cpl_q.status <= APU_VGPU_SPX_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_SPX_OK |->
        spx_o.valid && spx_o.word == spn_i.word);
    `endif
  end
endmodule

module g6lc_apu_vgpu_spx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_spn_t spn_i,
  input  apu_vgpu_lnr_t lnr_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_spx_cpl_t cpl_o,
  output apu_vgpu_spx_t spx_o
);
  g6lc_apu_vgpu_spx #(.Enable(Enable)) i_dut (.*);
endmodule
