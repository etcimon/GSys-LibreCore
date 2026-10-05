// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the ceiling sample at x = 0, y = 3. The earlier samples stay put.

// CeilingSampleCheck (smx): The ceiling sample at (0,3).
module g6lc_apu_vgpu_smx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_smp_t smp_i,
  input  apu_vgpu_y2r_t y2r_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_smx_cpl_t cpl_o,
  output apu_vgpu_smx_t smx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign smx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|smp_i) | (|y2r_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_smx_cpl_t cpl_q;
    apu_vgpu_smx_t smx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_smx_cpl_t'('0);
    assign smx_o = smx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        smx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (smx_q.valid) begin
            cpl_q.status <= APU_VGPU_SMX_FAULT;
          end else if (!smp_i.valid || !y2r_i.valid) begin
            cpl_q.status <= APU_VGPU_SMX_EMPTY;
          end else if (smp_i.y != 6'd3 || smp_i.x != 6'd0 ||
                       smp_i.word == y2r_i.at0 || smp_i.word == y2r_i.at1) begin
            cpl_q.status <= APU_VGPU_SMX_FAULT;
          end else begin
            smx_q.valid <= 1'b1;
            smx_q.word <= smp_i.word;
            cpl_q.status <= APU_VGPU_SMX_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_SMX_OK |->
        smx_o.valid && smx_o.word == smp_i.word);
    `endif
  end
endmodule

// CeilingSampleCheck (smx) enable-0 fixture: The ceiling sample at (0,3).
module g6lc_apu_vgpu_smx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_smp_t smp_i,
  input  apu_vgpu_y2r_t y2r_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_smx_cpl_t cpl_o,
  output apu_vgpu_smx_t smx_o
);
  g6lc_apu_vgpu_smx #(.Enable(Enable)) i_dut (.*);
endmodule
