// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the beat-1 offsets. A second store keeps the first.
// The image is not kept. The shader is not run.

module g6lc_apu_vgpu_b1k
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_b1r_t b1r_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b1k_cpl_t cpl_o,
  output apu_vgpu_b1k_t b1k_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign b1k_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|b1r_i) | (|gbd_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_b1k_cpl_t cpl_q;
    apu_vgpu_b1k_t b1k_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_b1k_cpl_t'('0);
    assign b1k_o = b1k_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        b1k_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (b1k_q.valid) begin
            cpl_q.status <= APU_VGPU_B1K_FAULT;
          end else if (!b1r_i.valid || !gbd_i.valid) begin
            cpl_q.status <= APU_VGPU_B1K_EMPTY;
          end else if (b1r_i.r != APU_VGPU_CLEAR_R ||
                       b1r_i.g != APU_VGPU_CLEAR_G ||
                       b1r_i.b != APU_VGPU_CLEAR_B ||
                       b1r_i.a != APU_VGPU_CLEAR_A ||
                       {b1r_i.a, b1r_i.b, b1r_i.g, b1r_i.r} != APU_VGPU_CLEAR_WORD ||
                       b1r_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       b1r_i.off8 != APU_VGPU_B1R_AT8 ||
                       b1r_i.off15 != APU_VGPU_B1R_AT15 ||
                       b1r_i.off8 == APU_VGPU_P7R_AT ||
                       b1r_i.off15 == APU_VGPU_X6R_AT ||
                       b1r_i.x8 != 7'd8 || b1r_i.x15 != 7'd15 ||
                       gbd_i.base != APU_VGPU_GBW_ADDR ||
                       gbd_i.bytes != APU_VGPU_GBD_BYTES) begin
            cpl_q.status <= APU_VGPU_B1K_FAULT;
          end else begin
            b1k_q.valid <= 1'b1;
            b1k_q.format <= b1r_i.format;
            b1k_q.off8 <= b1r_i.off8;
            b1k_q.off15 <= b1r_i.off15;
            b1k_q.x8 <= b1r_i.x8;
            b1k_q.x15 <= b1r_i.x15;
            b1k_q.r <= b1r_i.r;
            b1k_q.g <= b1r_i.g;
            b1k_q.b <= b1r_i.b;
            b1k_q.a <= b1r_i.a;
            cpl_q.status <= APU_VGPU_B1K_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(b1k_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_b1k_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_b1r_t b1r_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b1k_cpl_t cpl_o,
  output apu_vgpu_b1k_t b1k_o
);
  g6lc_apu_vgpu_b1k #(.Enable(Enable)) i_dut (.*);
endmodule
