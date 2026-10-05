// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// TEX of sampler view 5 after the guest ack of the transfer
// chain after scene guest ack. (0,0) is the clamp texel
// 32'hA5000000. (1,0) is the half blend 32'hD2008000. refused is
// 0. used.idx is 2. The clear word, a refused sample, and the
// scene used index record nothing. This is later than
// g6lc_apu_vgpu_ftk and later than g6lc_apu_vgpu_rgx. This is
// not g6lc_apu_vgpu_ftx, not g6lc_apu_vgpu_den, and not
// g6lc_apu_tgsi_compile. The compiler TEX opcode still returns
// -26. The sample was read from the backing. The image is not
// kept. This is not Mesa glReadPixels.

// TexAfterAck (gtx): TEX of sampler view 5 after that guest ack after scene guest ack.
// Interplay: TransferAckAfterAck (rga) <-> TexAfterAck (gtx)(ftk, rgx). See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_gtx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ftk_t ftk_i,
  input  apu_vgpu_rgx_t rgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gtx_cpl_t cpl_o,
  output apu_vgpu_gtx_t gtx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign gtx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|ftk_i) | (|rgx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_gtx_cpl_t cpl_q;
    apu_vgpu_gtx_t gtx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_gtx_cpl_t'('0);
    assign gtx_o = gtx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        gtx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (gtx_q.valid) begin
            cpl_q.status <= APU_VGPU_GTX_FAULT;
          end else if (!ftk_i.valid || !rgx_i.valid) begin
            cpl_q.status <= APU_VGPU_GTX_EMPTY;
          end else if (ftk_i.refused == 1'b1 ||
                       ftk_i.origin != APU_VGPU_FTX_ORIGIN ||
                       ftk_i.neighbor != APU_VGPU_FTX_NEIGHBOR ||
                       ftk_i.origin == APU_VGPU_CLEAR_WORD ||
                       ftk_i.neighbor == APU_VGPU_CLEAR_WORD ||
                       ftk_i.origin == ftk_i.neighbor ||
                       rgx_i.ack != APU_VGPU_TIW_REASON ||
                       rgx_i.remain != APU_VGPU_VAW_CLEAR ||
                       rgx_i.used_idx != APU_VGPU_TUW_IDXV ||
                       rgx_i.used_idx == APU_VGPU_QSU_IDXV) begin
            cpl_q.status <= APU_VGPU_GTX_FAULT;
          end else begin
            gtx_q.valid <= 1'b1;
            gtx_q.refused <= 1'b0;
            gtx_q.origin <= ftk_i.origin;
            gtx_q.neighbor <= ftk_i.neighbor;
            gtx_q.used_idx <= rgx_i.used_idx;
            cpl_q.status <= APU_VGPU_GTX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(gtx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_GTX_OK |->
        gtx_o.valid && gtx_o.refused == 1'b0 &&
        gtx_o.origin == APU_VGPU_FTX_ORIGIN &&
        gtx_o.neighbor == APU_VGPU_FTX_NEIGHBOR &&
        gtx_o.origin != APU_VGPU_CLEAR_WORD &&
        gtx_o.used_idx == APU_VGPU_TUW_IDXV);
    `endif
  end
endmodule

// TexAfterAck (gtx) enable-0 fixture: TEX of sampler view 5 after that guest ack after scene guest ack.
module g6lc_apu_vgpu_gtx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_ftk_t ftk_i,
  input  apu_vgpu_rgx_t rgx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_gtx_cpl_t cpl_o,
  output apu_vgpu_gtx_t gtx_o
);
  g6lc_apu_vgpu_gtx #(.Enable(Enable)) i_dut (.*);
endmodule
