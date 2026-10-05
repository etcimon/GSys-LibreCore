// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the TEX result of sampler view 5. refused stays 0. The
// clear word and a refused sample record nothing. A second store
// keeps the first. This is later than g6lc_apu_vgpu_ftx. This is
// not g6lc_apu_vgpu_den. The compiler TEX opcode still returns
// -26. This is not Mesa glReadPixels.

// TexSampleKeep (ftr): Keep that TEX result.
module g6lc_apu_vgpu_ftr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ftx_t ftx_i,
  input  apu_vgpu_tbn_t tbn_i,
  input  apu_vgpu_acx_t acx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ftr_cpl_t cpl_o,
  output apu_vgpu_ftr_t ftr_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign ftr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|ftx_i) | (|tbn_i) | (|acx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_ftr_cpl_t cpl_q;
    apu_vgpu_ftr_t ftr_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_ftr_cpl_t'('0);
    assign ftr_o = ftr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        ftr_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (ftr_q.valid) begin
            cpl_q.status <= APU_VGPU_FTR_FAULT;
          end else if (!ftx_i.valid || !tbn_i.valid || !acx_i.valid) begin
            cpl_q.status <= APU_VGPU_FTR_EMPTY;
          end else if (ftx_i.refused == 1'b1 ||
                       ftx_i.origin != APU_VGPU_FTX_ORIGIN ||
                       ftx_i.neighbor != APU_VGPU_FTX_NEIGHBOR ||
                       ftx_i.origin == APU_VGPU_CLEAR_WORD ||
                       ftx_i.origin == ftx_i.neighbor ||
                       ftx_i.resource_id != APU_VIRGL_RES_SCAN ||
                       ftx_i.view != APU_VIRGL_SV_HANDLE ||
                       ftx_i.view != tbn_i.view ||
                       acx_i.origin != ftx_i.origin) begin
            cpl_q.status <= APU_VGPU_FTR_FAULT;
          end else begin
            ftr_q.valid <= 1'b1;
            ftr_q.refused <= 1'b0;
            ftr_q.resource_id <= ftx_i.resource_id;
            ftr_q.view <= ftx_i.view;
            ftr_q.origin <= ftx_i.origin;
            ftr_q.neighbor <= ftx_i.neighbor;
            cpl_q.status <= APU_VGPU_FTR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(ftr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_FTR_OK |->
        ftr_o.valid && ftr_o.refused == 1'b0 &&
        ftr_o.origin != APU_VGPU_CLEAR_WORD);
    `endif
  end
endmodule

// TexSampleKeep (ftr) enable-0 fixture: Keep that TEX result.
module g6lc_apu_vgpu_ftr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ftx_t ftx_i,
  input  apu_vgpu_tbn_t tbn_i,
  input  apu_vgpu_acx_t acx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_ftr_cpl_t cpl_o,
  output apu_vgpu_ftr_t ftr_o
);
  g6lc_apu_vgpu_ftr #(.Enable(Enable)) i_dut (.*);
endmodule
