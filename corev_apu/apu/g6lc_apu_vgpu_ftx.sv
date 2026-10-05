// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// TEX of sampler view 5 on resource 1. (0,0) is the clamp texel
// 32'hA5000000. (1,0) is the half blend 32'hD2008000. refused is 0.
// The clear word records nothing. This is later than
// g6lc_apu_vgpu_den and later than g6lc_apu_vgpu_acx. The compiler
// TEX opcode still returns -26. This is not g6lc_apu_tgsi_compile.
// The sample was read from the backing. The image is not kept. This
// is not Mesa glReadPixels.

// TexSample (ftx): TEX of sampler view 5 returns the backing samples.
// Interplay: TexBind (tbn) <-> TexSample (ftx); lab pair, refused 0. See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_ftx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tbn_t tbn_i,
  input  apu_vgpu_acx_t acx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ftx_cpl_t cpl_o,
  output apu_vgpu_ftx_t ftx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign ftx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tbn_i) | (|acx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_ftx_cpl_t cpl_q;
    apu_vgpu_ftx_t ftx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_ftx_cpl_t'('0);
    assign ftx_o = ftx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        ftx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (ftx_q.valid) begin
            cpl_q.status <= APU_VGPU_FTX_FAULT;
          end else if (!tbn_i.valid || !acx_i.valid) begin
            cpl_q.status <= APU_VGPU_FTX_EMPTY;
          end else if (tbn_i.resource_id != APU_VIRGL_RES_SCAN ||
                       tbn_i.view != APU_VIRGL_SV_HANDLE ||
                       tbn_i.sampler != APU_VIRGL_SS_HANDLE ||
                       acx_i.origin != APU_VGPU_FTX_ORIGIN ||
                       acx_i.neighbor != APU_VGPU_FTX_NEIGHBOR ||
                       acx_i.origin == APU_VGPU_CLEAR_WORD ||
                       acx_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       acx_i.origin == acx_i.neighbor ||
                       acx_i.b0 != acx_i.neighbor[7:0] ||
                       acx_i.b0 == APU_VGPU_CLEAR_R ||
                       acx_i.b0 == APU_VGPU_CLEAR_B ||
                       acx_i.b0 == APU_VGPU_CLEAR_A) begin
            cpl_q.status <= APU_VGPU_FTX_FAULT;
          end else begin
            ftx_q.valid <= 1'b1;
            ftx_q.refused <= 1'b0;
            ftx_q.resource_id <= tbn_i.resource_id;
            ftx_q.view <= tbn_i.view;
            ftx_q.origin <= acx_i.origin;
            ftx_q.neighbor <= acx_i.neighbor;
            cpl_q.status <= APU_VGPU_FTX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(ftx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_FTX_OK |->
        ftx_o.valid && ftx_o.refused == 1'b0 &&
        ftx_o.origin == APU_VGPU_FTX_ORIGIN &&
        ftx_o.neighbor == APU_VGPU_FTX_NEIGHBOR &&
        ftx_o.origin != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// TexSample (ftx) enable-0 fixture: TEX of sampler view 5 returns the backing samples.
module g6lc_apu_vgpu_ftx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tbn_t tbn_i,
  input  apu_vgpu_acx_t acx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ftx_cpl_t cpl_o,
  output apu_vgpu_ftx_t ftx_o
);
  g6lc_apu_vgpu_ftx #(.Enable(Enable)) i_dut (.*);
endmodule
