// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the row-1 channels and the B8G8R8X8 tag. A second store keeps
// the first. The image is not kept. The shader is not run.

module g6lc_apu_vgpu_ryk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ryr_t ryr_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ryk_cpl_t cpl_o,
  output apu_vgpu_ryk_t ryk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign ryk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|ryr_i) | (|gbd_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_ryk_cpl_t cpl_q;
    apu_vgpu_ryk_t ryk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_ryk_cpl_t'('0);
    assign ryk_o = ryk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        ryk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (ryk_q.valid) begin
            cpl_q.status <= APU_VGPU_RYK_FAULT;
          end else if (!ryr_i.valid || !gbd_i.valid) begin
            cpl_q.status <= APU_VGPU_RYK_EMPTY;
          end else if (ryr_i.r != APU_VGPU_CLEAR_R ||
                       ryr_i.g != APU_VGPU_CLEAR_G ||
                       ryr_i.b != APU_VGPU_CLEAR_B ||
                       ryr_i.a != APU_VGPU_CLEAR_A ||
                       {ryr_i.a, ryr_i.b, ryr_i.g, ryr_i.r} != APU_VGPU_CLEAR_WORD ||
                       ryr_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       gbd_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       gbd_i.stride != APU_VGPU_GBD_STRIDE ||
                       gbd_i.bytes != APU_VGPU_GBD_BYTES) begin
            cpl_q.status <= APU_VGPU_RYK_FAULT;
          end else begin
            ryk_q.valid <= 1'b1;
            ryk_q.format <= ryr_i.format;
            ryk_q.r <= ryr_i.r;
            ryk_q.g <= ryr_i.g;
            ryk_q.b <= ryr_i.b;
            ryk_q.a <= ryr_i.a;
            cpl_q.status <= APU_VGPU_RYK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(ryk_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_ryk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ryr_t ryr_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ryk_cpl_t cpl_o,
  output apu_vgpu_ryk_t ryk_o
);
  g6lc_apu_vgpu_ryk #(.Enable(Enable)) i_dut (.*);
endmodule
