// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the byte offset and the lane. A second store keeps the first.
// The image is not kept. The shader is not run.

// ReadbackOffsetCheck (gbz): The offset and the lane.
module g6lc_apu_vgpu_gbz
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbo_t gbo_i,
  input  apu_vgpu_gof_t gof_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbz_cpl_t cpl_o,
  output apu_vgpu_gbz_t gbz_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gbz_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|gbo_i) | (|gof_i) | (|gbd_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gbz_cpl_t cpl_q;
    apu_vgpu_gbz_t gbz_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gbz_cpl_t'('0);
    assign gbz_o = gbz_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gbz_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gbz_q.valid) begin
            cpl_q.status <= APU_VGPU_GBZ_FAULT;
          end else if (!gbo_i.valid || !gof_i.valid || !gbd_i.valid) begin
            cpl_q.status <= APU_VGPU_GBZ_EMPTY;
          end else if (gbo_i.word != APU_VGPU_CLEAR_WORD ||
                       gbo_i.offset != gof_i.offset ||
                       gbo_i.x != gof_i.x || gbo_i.y != gof_i.y ||
                       gbo_i.x >= 7'd64 || gbo_i.y >= 7'd64 ||
                       32'(gbo_i.offset) + 32'd4 > gbd_i.bytes ||
                       gbd_i.bytes != APU_VGPU_GBD_BYTES ||
                       gbd_i.base != APU_VGPU_GBW_ADDR) begin
            cpl_q.status <= APU_VGPU_GBZ_FAULT;
          end else begin
            gbz_q.valid <= 1'b1;
            gbz_q.word <= gbo_i.word;
            gbz_q.offset <= gbo_i.offset;
            gbz_q.bytes <= gbd_i.bytes;
            gbz_q.x <= gbo_i.x;
            gbz_q.y <= gbo_i.y;
            cpl_q.status <= APU_VGPU_GBZ_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(gbz_o));
    `endif
  end
endmodule

// ReadbackOffsetCheck (gbz) enable-0 fixture: The offset and the lane.
module g6lc_apu_vgpu_gbz_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbo_t gbo_i,
  input  apu_vgpu_gof_t gof_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbz_cpl_t cpl_o,
  output apu_vgpu_gbz_t gbz_o
);
  g6lc_apu_vgpu_gbz #(.Enable(Enable)) i_dut (.*);
endmodule
