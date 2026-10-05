// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the 64 by 64 rectangle and the sampled lane. A second store
// keeps the first. The image is not kept. The shader is not run.

// ReadbackRectCheck (gbx): The rectangle and the sampled lane.
module g6lc_apu_vgpu_gbx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbl_t gbl_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_gbk_t gbk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbx_cpl_t cpl_o,
  output apu_vgpu_gbx_t gbx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gbx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|gbl_i) | (|gbd_i) | (|gbk_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gbx_cpl_t cpl_q;
    apu_vgpu_gbx_t gbx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gbx_cpl_t'('0);
    assign gbx_o = gbx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gbx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gbx_q.valid) begin
            cpl_q.status <= APU_VGPU_GBX_FAULT;
          end else if (!gbl_i.valid || !gbd_i.valid || !gbk_i.valid) begin
            cpl_q.status <= APU_VGPU_GBX_EMPTY;
          end else if (gbl_i.word != APU_VGPU_CLEAR_WORD ||
                       gbl_i.word != gbk_i.word ||
                       gbl_i.x >= 7'd64 || gbl_i.y >= 7'd64 ||
                       gbd_i.width != APU_VGPU_GBD_W ||
                       gbd_i.height != APU_VGPU_GBD_H ||
                       gbd_i.bytes != APU_VGPU_GBD_BYTES ||
                       gbd_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       gbd_i.base != APU_VGPU_GBW_ADDR ||
                       gbl_i.addr < gbd_i.base) begin
            cpl_q.status <= APU_VGPU_GBX_FAULT;
          end else begin
            gbx_q.valid <= 1'b1;
            gbx_q.width <= gbd_i.width;
            gbx_q.height <= gbd_i.height;
            gbx_q.bytes <= gbd_i.bytes;
            gbx_q.word <= gbl_i.word;
            gbx_q.x <= gbl_i.x;
            gbx_q.y <= gbl_i.y;
            cpl_q.status <= APU_VGPU_GBX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(gbx_o));
    `endif
  end
endmodule

// ReadbackRectCheck (gbx) enable-0 fixture: The rectangle and the sampled lane.
module g6lc_apu_vgpu_gbx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gbl_t gbl_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  apu_vgpu_gbk_t gbk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gbx_cpl_t cpl_o,
  output apu_vgpu_gbx_t gbx_o
);
  g6lc_apu_vgpu_gbx #(.Enable(Enable)) i_dut (.*);
endmodule
