// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Control queue 0 after avail index 1. The cursor queue and the
// transfer index 2 record nothing. A second store keeps the first.
// This is later than g6lc_apu_vgpu_snr. This is not
// g6lc_apu_vgpu_qnx and not g6lc_apu_virtio_mmio. The compiler TEX opcode still returns
// -26. This is not Mesa glReadPixels.

// SceneQueueNotifyCheck (sny): Control queue 0 after avail index 1.
// Interplay: SceneQueueNotify (snt) <-> SceneQueueNotifyCheck (sny); parent of GuestNextWalk (gnw). See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_sny
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_snr_t snr_i,
  input  apu_vgpu_snt_t snt_i,
  input  apu_vgpu_snx_t snx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sny_cpl_t cpl_o,
  output apu_vgpu_sny_t sny_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign sny_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|snr_i) | (|snt_i) | (|snx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_sny_cpl_t cpl_q;
    apu_vgpu_sny_t sny_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_sny_cpl_t'('0);
    assign sny_o = sny_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        sny_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (sny_q.valid) begin
            cpl_q.status <= APU_VGPU_SNY_FAULT;
          end else if (!snr_i.valid || !snt_i.valid || !snx_i.valid) begin
            cpl_q.status <= APU_VGPU_SNY_EMPTY;
          end else if (snr_i.qid != APU_VGPU_QNT_QUEUE ||
                       snr_i.qid == APU_VGPU_QNT_CURSOR ||
                       snr_i.avail_idx != APU_VGPU_QSU_IDXV ||
                       snr_i.avail_idx == APU_VGPU_TUW_IDXV ||
                       snr_i.addr != APU_VGPU_SNT_ADDR ||
                       snr_i.qid != snt_i.qid ||
                       snx_i.avail_idx != APU_VGPU_QSU_IDXV) begin
            cpl_q.status <= APU_VGPU_SNY_FAULT;
          end else begin
            sny_q.valid <= 1'b1;
            sny_q.qid <= snr_i.qid;
            sny_q.avail_idx <= snr_i.avail_idx;
            cpl_q.status <= APU_VGPU_SNY_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(sny_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SNY_OK |->
        sny_o.valid && sny_o.qid == APU_VGPU_QNT_QUEUE &&
        sny_o.avail_idx == APU_VGPU_QSU_IDXV);
    `endif
  end
endmodule

// SceneQueueNotifyCheck (sny) enable-0 fixture: Control queue 0 after avail index 1.
module g6lc_apu_vgpu_sny_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_snr_t snr_i,
  input  apu_vgpu_snt_t snt_i,
  input  apu_vgpu_snx_t snx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sny_cpl_t cpl_o,
  output apu_vgpu_sny_t sny_o
);
  g6lc_apu_vgpu_sny #(.Enable(Enable)) i_dut (.*);
endmodule
