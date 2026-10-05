// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep (63,63). A second store keeps the first. The image is not
// kept. The shader is not run.

// ReadbackFarCornerKeep (tck): That offset and the channels.
module g6lc_apu_vgpu_tck
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tcr_t tcr_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tck_cpl_t cpl_o,
  output apu_vgpu_tck_t tck_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tck_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tcr_i) | (|gbd_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_tck_cpl_t cpl_q;
    apu_vgpu_tck_t tck_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tck_cpl_t'('0);
    assign tck_o = tck_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tck_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tck_q.valid) begin
            cpl_q.status <= APU_VGPU_TCK_FAULT;
          end else if (!tcr_i.valid || !gbd_i.valid) begin
            cpl_q.status <= APU_VGPU_TCK_EMPTY;
          end else if (tcr_i.r != APU_VGPU_CLEAR_R ||
                       tcr_i.g != APU_VGPU_CLEAR_G ||
                       tcr_i.b != APU_VGPU_CLEAR_B ||
                       tcr_i.a != APU_VGPU_CLEAR_A ||
                       {tcr_i.a, tcr_i.b, tcr_i.g, tcr_i.r} != APU_VGPU_CLEAR_WORD ||
                       tcr_i.format != APU_VIRGL_FMT_B8G8R8X8 ||
                       tcr_i.offset != APU_VGPU_GOF_LAST ||
                       tcr_i.offset == APU_VGPU_X6R_AT ||
                       tcr_i.offset == APU_VGPU_TPR_AT063 ||
                       tcr_i.x != 7'd63 || tcr_i.y != 7'd63 ||
                       gbd_i.base != APU_VGPU_GBW_ADDR ||
                       gbd_i.bytes != APU_VGPU_GBD_BYTES) begin
            cpl_q.status <= APU_VGPU_TCK_FAULT;
          end else begin
            tck_q.valid <= 1'b1;
            tck_q.format <= tcr_i.format;
            tck_q.offset <= tcr_i.offset;
            tck_q.x <= tcr_i.x;
            tck_q.y <= tcr_i.y;
            tck_q.r <= tcr_i.r;
            tck_q.g <= tcr_i.g;
            tck_q.b <= tcr_i.b;
            tck_q.a <= tcr_i.a;
            cpl_q.status <= APU_VGPU_TCK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(tck_o));
    `endif
  end
endmodule

// ReadbackFarCornerKeep (tck) enable-0 fixture: That offset and the channels.
module g6lc_apu_vgpu_tck_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tcr_t tcr_i,
  input  apu_vgpu_gbd_t gbd_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tck_cpl_t cpl_o,
  output apu_vgpu_tck_t tck_o
);
  g6lc_apu_vgpu_tck #(.Enable(Enable)) i_dut (.*);
endmodule
