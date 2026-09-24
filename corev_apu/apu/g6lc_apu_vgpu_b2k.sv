// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep (16,0) and (23,0). A second store keeps the first.
// The image is not kept. The shader is not run.

module g6lc_apu_vgpu_b2k
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_b2r_t b2r_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b2k_cpl_t cpl_o,
  output apu_vgpu_b2k_t b2k_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign b2k_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|b2r_i) | (|gbd_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_b2k_cpl_t cpl_q;
    apu_vgpu_b2k_t b2k_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_b2k_cpl_t'('0);
    assign b2k_o = b2k_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        b2k_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (b2k_q.valid) begin
            cpl_q.status <= APU_VGPU_B2K_FAULT;
          end else if (!b2r_i.valid || !gbd_i.valid) begin
            cpl_q.status <= APU_VGPU_B2K_EMPTY;
          end else if (b2r_i.r != APU_VGPU_CLEAR_R ||
                       b2r_i.g != APU_VGPU_CLEAR_G ||
                       b2r_i.b != APU_VGPU_CLEAR_B ||
                       b2r_i.a != APU_VGPU_CLEAR_A ||
                       {b2r_i.a, b2r_i.b, b2r_i.g, b2r_i.r} != APU_VGPU_CLEAR_WORD ||
                       b2r_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       b2r_i.off16 != APU_VGPU_B2R_AT16 ||
                       b2r_i.off23 != APU_VGPU_B2R_AT23 ||
                       b2r_i.off16 == b2r_i.off23 ||
                       b2r_i.x16 != 7'd16 || b2r_i.x23 != 7'd23 ||
                       gbd_i.base != APU_VGPU_GBW_ADDR ||
                       gbd_i.bytes != APU_VGPU_GBD_BYTES) begin
            cpl_q.status <= APU_VGPU_B2K_FAULT;
          end else begin
            b2k_q.valid <= 1'b1;
            b2k_q.format <= b2r_i.format;
            b2k_q.off16 <= b2r_i.off16;
            b2k_q.off23 <= b2r_i.off23;
            b2k_q.x16 <= b2r_i.x16;
            b2k_q.x23 <= b2r_i.x23;
            b2k_q.r <= b2r_i.r;
            b2k_q.g <= b2r_i.g;
            b2k_q.b <= b2r_i.b;
            b2k_q.a <= b2r_i.a;
            cpl_q.status <= APU_VGPU_B2K_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(b2k_o));
    `endif
  end
endmodule

module g6lc_apu_vgpu_b2k_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_b2r_t b2r_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_b2k_cpl_t cpl_o,
  output apu_vgpu_b2k_t b2k_o
);
  g6lc_apu_vgpu_b2k #(.Enable(Enable)) i_dut (.*);
endmodule
