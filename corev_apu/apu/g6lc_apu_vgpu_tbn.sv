// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// The TEX program names sampler view 5 on resource 1 and sampler
// state 6. Both are bound on fragment slot 0. A different handle
// or resource records nothing. This does not fetch a texel.

module g6lc_apu_vgpu_tbn
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fst_t fst_i,
  input  apu_vgpu_fsb_t fsb_i,
  input  apu_vgpu_sv_t sv_i,
  input  apu_vgpu_ss_t ss_i,
  input  apu_vgpu_svb_t svb_i,
  input  apu_vgpu_ssb_t ssb_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tbn_cpl_t cpl_o,
  output apu_vgpu_tbn_t tbn_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tbn_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|fst_i) | (|fsb_i) | (|sv_i) | (|ss_i) |
                        (|svb_i) | (|ssb_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_tbn_cpl_t cpl_q;
    apu_vgpu_tbn_t tbn_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tbn_cpl_t'('0);
    assign tbn_o = tbn_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tbn_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tbn_q.valid) begin
            cpl_q.status <= APU_VGPU_TBN_FAULT;
          end else if (!fst_i.valid || !fsb_i.valid || !sv_i.valid ||
                       !ss_i.valid || !svb_i.valid || !ssb_i.valid) begin
            cpl_q.status <= APU_VGPU_TBN_EMPTY;
          end else if (!fst_i.tex ||
                       fsb_i.handle != APU_VIRGL_FS_HANDLE ||
                       fsb_i.stage != APU_VIRGL_SHADER_FRAGMENT ||
                       fsb_i.next != APU_VIRGL_FSB_NEXT ||
                       sv_i.handle != APU_VIRGL_SV_HANDLE ||
                       sv_i.resource_id != APU_VIRGL_RES_SCAN ||
                       32'(sv_i.format) != APU_VIRGL_FMT_B8G8R8X8 ||
                       sv_i.target != APU_VIRGL_TARGET_2D ||
                       sv_i.swizzle != APU_VIRGL_SWIZZLE_IDENTITY ||
                       sv_i.next != APU_VIRGL_SV_NEXT ||
                       ss_i.handle != APU_VIRGL_SS_HANDLE ||
                       ss_i.s0 != APU_VIRGL_SSTATE_S0 ||
                       ss_i.max_lod != APU_VIRGL_SSTATE_MAX_LOD ||
                       ss_i.next != APU_VIRGL_SS_NEXT ||
                       ssb_i.stage != APU_VIRGL_SHADER_FRAGMENT ||
                       ssb_i.slot != 32'd0 ||
                       ssb_i.handle != APU_VIRGL_SS_HANDLE ||
                       ssb_i.next != APU_VIRGL_SSB_NEXT ||
                       svb_i.stage != APU_VIRGL_SHADER_FRAGMENT ||
                       svb_i.slot != 32'd0 ||
                       svb_i.handle != APU_VIRGL_SV_HANDLE ||
                       svb_i.next != APU_VIRGL_SVB_NEXT) begin
            cpl_q.status <= APU_VGPU_TBN_FAULT;
          end else begin
            tbn_q.valid <= 1'b1;
            tbn_q.resource_id <= sv_i.resource_id;
            tbn_q.view <= sv_i.handle;
            tbn_q.sampler <= ss_i.handle;
            cpl_q.status <= APU_VGPU_TBN_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(tbn_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_TBN_OK |->
        tbn_o.valid && tbn_o.resource_id == APU_VIRGL_RES_SCAN &&
        tbn_o.view == APU_VIRGL_SV_HANDLE &&
        tbn_o.sampler == APU_VIRGL_SS_HANDLE);
    `endif
  end
endmodule

module g6lc_apu_vgpu_tbn_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_fst_t fst_i,
  input  apu_vgpu_fsb_t fsb_i,
  input  apu_vgpu_sv_t sv_i,
  input  apu_vgpu_ss_t ss_i,
  input  apu_vgpu_svb_t svb_i,
  input  apu_vgpu_ssb_t ssb_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tbn_cpl_t cpl_o,
  output apu_vgpu_tbn_t tbn_o
);
  g6lc_apu_vgpu_tbn #(.Enable(Enable)) i_dut (.*);
endmodule
