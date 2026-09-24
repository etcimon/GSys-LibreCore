// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// The bound sample names resource 1. This unit has no texel memory,
// so the sample is refused and the word stays the clear color. This
// does not fetch a texel.

module g6lc_apu_vgpu_den
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tbn_t tbn_i,
  input  apu_vgpu_cv_t cv_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_den_cpl_t cpl_o,
  output apu_vgpu_den_t den_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign den_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tbn_i) | (|cv_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_den_cpl_t cpl_q;
    apu_vgpu_den_t den_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_den_cpl_t'('0);
    assign den_o = den_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        den_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (den_q.valid) begin
            cpl_q.status <= APU_VGPU_DEN_FAULT;
          end else if (!tbn_i.valid || !cv_i.valid) begin
            cpl_q.status <= APU_VGPU_DEN_EMPTY;
          end else if (!cv_i.covered || cv_i.word != APU_VGPU_CLEAR_WORD ||
                       cv_i.samples != APU_VGPU_FILL_N ||
                       tbn_i.resource_id != APU_VIRGL_RES_SCAN ||
                       tbn_i.view != APU_VIRGL_SV_HANDLE ||
                       tbn_i.sampler != APU_VIRGL_SS_HANDLE) begin
            cpl_q.status <= APU_VGPU_DEN_FAULT;
          end else begin
            den_q.valid <= 1'b1;
            den_q.refused <= 1'b1;
            den_q.resource_id <= tbn_i.resource_id;
            den_q.word <= cv_i.word;
            den_q.samples <= cv_i.samples;
            cpl_q.status <= APU_VGPU_DEN_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(den_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_DEN_OK |->
        den_o.valid && den_o.refused &&
        den_o.resource_id == APU_VIRGL_RES_SCAN &&
        den_o.word == APU_VGPU_CLEAR_WORD &&
        den_o.samples == APU_VGPU_FILL_N);
    `endif
  end
endmodule

module g6lc_apu_vgpu_den_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tbn_t tbn_i,
  input  apu_vgpu_cv_t cv_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_den_cpl_t cpl_o,
  output apu_vgpu_den_t den_o
);
  g6lc_apu_vgpu_den #(.Enable(Enable)) i_dut (.*);
endmodule
