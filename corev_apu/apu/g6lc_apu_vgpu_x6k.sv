// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep (63,0). A second store keeps the first. The image is not
// kept. The shader is not run.

module g6lc_apu_vgpu_x6k
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_x6r_t x6r_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_x6k_cpl_t cpl_o,
  output apu_vgpu_x6k_t x6k_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign x6k_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|x6r_i) | (|gbd_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_x6k_cpl_t cpl_q;
    apu_vgpu_x6k_t x6k_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_x6k_cpl_t'('0);
    assign x6k_o = x6k_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        x6k_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (x6k_q.valid) begin
            cpl_q.status <= APU_VGPU_X6K_FAULT;
          end else if (!x6r_i.valid || !gbd_i.valid) begin
            cpl_q.status <= APU_VGPU_X6K_EMPTY;
          end else if (x6r_i.r != APU_VGPU_CLEAR_R ||
                       x6r_i.g != APU_VGPU_CLEAR_G ||
                       x6r_i.b != APU_VGPU_CLEAR_B ||
                       x6r_i.a != APU_VGPU_CLEAR_A ||
                       {x6r_i.a, x6r_i.b, x6r_i.g, x6r_i.r} != APU_VGPU_CLEAR_WORD ||
                       x6r_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       x6r_i.offset != APU_VGPU_X6R_AT ||
                       x6r_i.offset == APU_VGPU_TPR_AT063 ||
                       x6r_i.x != 7'd63 || x6r_i.y != 7'd0 ||
                       gbd_i.base != APU_VGPU_GBW_ADDR ||
                       gbd_i.bytes != APU_VGPU_GBD_BYTES) begin
            cpl_q.status <= APU_VGPU_X6K_FAULT;
          end else begin
            x6k_q.valid <= 1'b1;
            x6k_q.format <= x6r_i.format;
            x6k_q.offset <= x6r_i.offset;
            x6k_q.x <= x6r_i.x;
            x6k_q.y <= x6r_i.y;
            x6k_q.r <= x6r_i.r;
            x6k_q.g <= x6r_i.g;
            x6k_q.b <= x6r_i.b;
            x6k_q.a <= x6r_i.a;
            cpl_q.status <= APU_VGPU_X6K_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(x6k_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_x6k_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_x6r_t x6r_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_x6k_cpl_t cpl_o,
  output apu_vgpu_x6k_t x6k_o
);
  g6lc_apu_vgpu_x6k #(.Enable(Enable)) i_dut (.*);
endmodule
