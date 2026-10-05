// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Avail index 1 at 64'h8800E200 after scene QueueNotify of queue 0.
// The transfer index 2 and the transfer ring record nothing. A second
// store keeps the first. This is later than g6lc_apu_vgpu_sak.
// This is not g6lc_apu_vgpu_qax and not g6lc_apu_vgpu_avail. The compiler TEX opcode still
// returns -26. This is not Mesa glReadPixels.

// SceneAvailAfterNotifyCheck (sax): Avail index 1 at 64'h8800E200 after notify.
module g6lc_apu_vgpu_sax
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sak_t sak_i,
  input  apu_vgpu_sav_t sav_i,
  input  apu_vgpu_sny_t sny_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sax_cpl_t cpl_o,
  output apu_vgpu_sax_t sax_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign sax_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|sak_i) | (|sav_i) | (|sny_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_sax_cpl_t cpl_q;
    apu_vgpu_sax_t sax_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_sax_cpl_t'('0);
    assign sax_o = sax_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        sax_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (sax_q.valid) begin
            cpl_q.status <= APU_VGPU_SAX_FAULT;
          end else if (!sak_i.valid || !sav_i.valid || !sny_i.valid) begin
            cpl_q.status <= APU_VGPU_SAX_EMPTY;
          end else if (sak_i.avail_idx != APU_VGPU_QSU_IDXV ||
                       sak_i.avail_idx == APU_VGPU_TUW_IDXV ||
                       sak_i.addr != APU_VGPU_SAV_ADDR ||
                       sak_i.addr == APU_VGPU_QAV_ADDR ||
                       sak_i.avail_idx != sav_i.avail_idx ||
                       sny_i.qid != APU_VGPU_QNT_QUEUE ||
                       sny_i.qid == APU_VGPU_QNT_CURSOR ||
                       sny_i.avail_idx != APU_VGPU_QSU_IDXV) begin
            cpl_q.status <= APU_VGPU_SAX_FAULT;
          end else begin
            sax_q.valid <= 1'b1;
            sax_q.avail_idx <= sak_i.avail_idx;
            cpl_q.status <= APU_VGPU_SAX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(sax_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SAX_OK |->
        sax_o.valid && sax_o.avail_idx == APU_VGPU_QSU_IDXV);
    `endif
  end
endmodule

// SceneAvailAfterNotifyCheck (sax) enable-0 fixture: Avail index 1 at 64'h8800E200 after notify.
module g6lc_apu_vgpu_sax_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sak_t sak_i,
  input  apu_vgpu_sav_t sav_i,
  input  apu_vgpu_sny_t sny_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sax_cpl_t cpl_o,
  output apu_vgpu_sax_t sax_o
);
  g6lc_apu_vgpu_sax #(.Enable(Enable)) i_dut (.*);
endmodule
