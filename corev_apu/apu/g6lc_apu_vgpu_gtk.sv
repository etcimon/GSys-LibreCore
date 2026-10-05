// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// refused is 0 after that guest ack. The origin is the clamp
// texel, not the clear word. used.idx is 2, not the scene index
// 1. A refused sample or the scene used index records nothing.
// A second store keeps the first. This is later than
// g6lc_apu_vgpu_gtr. This is not g6lc_apu_vgpu_ftk and not
// g6lc_apu_vgpu_dnr. The compiler TEX opcode still returns -26.
// This is not Mesa glReadPixels.

// TexAfterAckCheck (gtk): refused 0 origin clamp texel after that guest ack.
module g6lc_apu_vgpu_gtk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gtr_t gtr_i,
  input  apu_vgpu_gtx_t gtx_i,
  input  apu_vgpu_ftk_t ftk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gtk_cpl_t cpl_o,
  output apu_vgpu_gtk_t gtk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gtk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|gtr_i) | (|gtx_i) | (|ftk_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gtk_cpl_t cpl_q;
    apu_vgpu_gtk_t gtk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gtk_cpl_t'('0);
    assign gtk_o = gtk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gtk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gtk_q.valid) begin
            cpl_q.status <= APU_VGPU_GTK_FAULT;
          end else if (!gtr_i.valid || !gtx_i.valid || !ftk_i.valid) begin
            cpl_q.status <= APU_VGPU_GTK_EMPTY;
          end else if (gtr_i.refused == 1'b1 ||
                       gtr_i.origin != APU_VGPU_FTX_ORIGIN ||
                       gtr_i.neighbor != APU_VGPU_FTX_NEIGHBOR ||
                       gtr_i.origin == APU_VGPU_CLEAR_WORD ||
                       gtr_i.origin == gtr_i.neighbor ||
                       gtr_i.origin[7:0] == APU_VGPU_CLEAR_R ||
                       gtr_i.used_idx != APU_VGPU_TUW_IDXV ||
                       gtr_i.used_idx == APU_VGPU_QSU_IDXV ||
                       gtr_i.origin != gtx_i.origin ||
                       ftk_i.refused == 1'b1) begin
            cpl_q.status <= APU_VGPU_GTK_FAULT;
          end else begin
            gtk_q.valid <= 1'b1;
            gtk_q.refused <= 1'b0;
            gtk_q.origin <= gtr_i.origin;
            gtk_q.used_idx <= gtr_i.used_idx;
            cpl_q.status <= APU_VGPU_GTK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(gtk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_GTK_OK |->
        gtk_o.valid && gtk_o.refused == 1'b0 &&
        gtk_o.origin == APU_VGPU_FTX_ORIGIN &&
        gtk_o.origin != APU_VGPU_CLEAR_WORD &&
        gtk_o.used_idx == APU_VGPU_TUW_IDXV);
    `endif
  end
endmodule

// TexAfterAckCheck (gtk) enable-0 fixture: refused 0 origin clamp texel after that guest ack.
module g6lc_apu_vgpu_gtk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gtr_t gtr_i,
  input  apu_vgpu_gtx_t gtx_i,
  input  apu_vgpu_ftk_t ftk_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gtk_cpl_t cpl_o,
  output apu_vgpu_gtk_t gtk_o
);
  g6lc_apu_vgpu_gtk #(.Enable(Enable)) i_dut (.*);
endmodule
