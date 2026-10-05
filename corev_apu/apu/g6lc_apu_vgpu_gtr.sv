// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Keep the TEX result after that guest ack. refused stays 0.
// used.idx stays 2. The clear word, a refused sample, and the
// scene used index record nothing. A second store keeps the
// first. This is later than g6lc_apu_vgpu_gtx. This is not
// g6lc_apu_vgpu_ftr and not g6lc_apu_vgpu_den. The compiler TEX
// opcode still returns -26. This is not Mesa glReadPixels.

// TexAfterAckKeep (gtr): Guest keep of that TEX result.
module g6lc_apu_vgpu_gtr
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gtx_t gtx_i,
  input  apu_vgpu_ftk_t ftk_i,
  input  apu_vgpu_rgx_t rgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gtr_cpl_t cpl_o,
  output apu_vgpu_gtr_t gtr_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gtr_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|gtx_i) | (|ftk_i) | (|rgx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gtr_cpl_t cpl_q;
    apu_vgpu_gtr_t gtr_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gtr_cpl_t'('0);
    assign gtr_o = gtr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gtr_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gtr_q.valid) begin
            cpl_q.status <= APU_VGPU_GTR_FAULT;
          end else if (!gtx_i.valid || !ftk_i.valid || !rgx_i.valid) begin
            cpl_q.status <= APU_VGPU_GTR_EMPTY;
          end else if (gtx_i.refused == 1'b1 ||
                       gtx_i.origin != APU_VGPU_FTX_ORIGIN ||
                       gtx_i.neighbor != APU_VGPU_FTX_NEIGHBOR ||
                       gtx_i.origin == APU_VGPU_CLEAR_WORD ||
                       gtx_i.origin == gtx_i.neighbor ||
                       gtx_i.used_idx != APU_VGPU_TUW_IDXV ||
                       gtx_i.used_idx == APU_VGPU_QSU_IDXV ||
                       gtx_i.origin != ftk_i.origin ||
                       rgx_i.used_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_GTR_FAULT;
          end else begin
            gtr_q.valid <= 1'b1;
            gtr_q.refused <= 1'b0;
            gtr_q.origin <= gtx_i.origin;
            gtr_q.neighbor <= gtx_i.neighbor;
            gtr_q.used_idx <= gtx_i.used_idx;
            cpl_q.status <= APU_VGPU_GTR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(gtr_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_GTR_OK |->
        gtr_o.valid && gtr_o.refused == 1'b0 &&
        gtr_o.origin != APU_VGPU_CLEAR_WORD &&
        gtr_o.used_idx == APU_VGPU_TUW_IDXV);
    `endif
  end
endmodule

// TexAfterAckKeep (gtr) enable-0 fixture: Guest keep of that TEX result.
module g6lc_apu_vgpu_gtr_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_gtx_t gtx_i,
  input  apu_vgpu_ftk_t ftk_i,
  input  apu_vgpu_rgx_t rgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gtr_cpl_t cpl_o,
  output apu_vgpu_gtr_t gtr_o
);
  g6lc_apu_vgpu_gtr #(.Enable(Enable)) i_dut (.*);
endmodule
