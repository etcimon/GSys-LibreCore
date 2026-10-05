// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// refused is 0. The origin is the clamp texel, not the clear word.
// A refused sample or the clear color records nothing. This is
// later than g6lc_apu_vgpu_ftr. This is not g6lc_apu_vgpu_dnr.
// The compiler TEX opcode still returns -26. This is not Mesa
// glReadPixels.

// TexSampleCheck (ftk): refused is 0 and the word is not the clear color.
module g6lc_apu_vgpu_ftk
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ftr_t ftr_i,
  input  apu_vgpu_ftx_t ftx_i,
  input  apu_vgpu_tbn_t tbn_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ftk_cpl_t cpl_o,
  output apu_vgpu_ftk_t ftk_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign ftk_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|ftr_i) | (|ftx_i) | (|tbn_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_ftk_cpl_t cpl_q;
    apu_vgpu_ftk_t ftk_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_ftk_cpl_t'('0);
    assign ftk_o = ftk_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        ftk_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (ftk_q.valid) begin
            cpl_q.status <= APU_VGPU_FTK_FAULT;
          end else if (!ftr_i.valid || !ftx_i.valid || !tbn_i.valid) begin
            cpl_q.status <= APU_VGPU_FTK_EMPTY;
          end else if (ftr_i.refused == 1'b1 ||
                       ftr_i.origin != APU_VGPU_FTX_ORIGIN ||
                       ftr_i.neighbor != APU_VGPU_FTX_NEIGHBOR ||
                       ftr_i.origin == APU_VGPU_CLEAR_WORD ||
                       ftr_i.origin == ftr_i.neighbor ||
                       ftr_i.origin[7:0] == APU_VGPU_CLEAR_R ||
                       ftr_i.view != APU_VIRGL_SV_HANDLE ||
                       ftr_i.origin != ftx_i.origin ||
                       tbn_i.view != APU_VIRGL_SV_HANDLE) begin
            cpl_q.status <= APU_VGPU_FTK_FAULT;
          end else begin
            ftk_q.valid <= 1'b1;
            ftk_q.refused <= 1'b0;
            ftk_q.origin <= ftr_i.origin;
            ftk_q.neighbor <= ftr_i.neighbor;
            cpl_q.status <= APU_VGPU_FTK_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(ftk_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_FTK_OK |->
        ftk_o.valid && ftk_o.refused == 1'b0 &&
        ftk_o.origin == APU_VGPU_FTX_ORIGIN &&
        ftk_o.origin != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// TexSampleCheck (ftk) enable-0 fixture: refused is 0 and the word is not the clear color.
module g6lc_apu_vgpu_ftk_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ftr_t ftr_i,
  input  apu_vgpu_ftx_t ftx_i,
  input  apu_vgpu_tbn_t tbn_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ftk_cpl_t cpl_o,
  output apu_vgpu_ftk_t ftk_o
);
  g6lc_apu_vgpu_ftk #(.Enable(Enable)) i_dut (.*);
endmodule
