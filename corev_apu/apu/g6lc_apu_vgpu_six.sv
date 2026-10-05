// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Reason 32'h1 at 64'h8800E500 with used.idx 1 after the scene
// used ring after QueueNotify. The transfer status word at
// 64'h880C0000 records nothing. Index 2 records nothing. This
// is later than g6lc_apu_vgpu_sir. This is not
// g6lc_apu_vgpu_qsm, not g6lc_apu_vgpu_qix, and not
// g6lc_apu_vgpu_vik. The pin is not kept. TEX is not the
// compiler opcode. This is not Mesa glReadPixels.

// SceneIrqAfterNotifyCheck (six): Reason 32'h1 at 64'h8800E500 after scene used after notify.
module g6lc_apu_vgpu_six
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sir_t sir_i,
  input  apu_vgpu_siw_t siw_i,
  input  apu_vgpu_slx_t slx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_six_cpl_t cpl_o,
  output apu_vgpu_six_t six_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign six_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|sir_i) | (|siw_i) | (|slx_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_six_cpl_t cpl_q;
    apu_vgpu_six_t six_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_six_cpl_t'('0);
    assign six_o = six_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        six_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (six_q.valid) begin
            cpl_q.status <= APU_VGPU_SIX_FAULT;
          end else if (!sir_i.valid || !siw_i.valid || !slx_i.valid) begin
            cpl_q.status <= APU_VGPU_SIX_EMPTY;
          end else if (sir_i.reason != APU_VGPU_QSI_REASON ||
                       sir_i.used_idx != APU_VGPU_QSU_IDXV ||
                       sir_i.used_idx == APU_VGPU_TUW_IDXV ||
                       sir_i.addr != APU_VGPU_QSI_ADDR ||
                       sir_i.addr == APU_VGPU_TIW_ADDR ||
                       sir_i.reason != siw_i.reason ||
                       sir_i.used_idx != siw_i.used_idx ||
                       slx_i.used_idx != APU_VGPU_QSU_IDXV) begin
            cpl_q.status <= APU_VGPU_SIX_FAULT;
          end else begin
            six_q.valid <= 1'b1;
            six_q.reason <= sir_i.reason;
            six_q.used_idx <= sir_i.used_idx;
            six_q.addr <= sir_i.addr;
            cpl_q.status <= APU_VGPU_SIX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(six_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SIX_OK |->
        six_o.valid && six_o.reason == APU_VGPU_QSI_REASON &&
        six_o.used_idx == APU_VGPU_QSU_IDXV &&
        six_o.addr != APU_VGPU_TIW_ADDR);
    `endif
  end
endmodule

// SceneIrqAfterNotifyCheck (six) enable-0 fixture: Reason 32'h1 at 64'h8800E500 after scene used after notify.
module g6lc_apu_vgpu_six_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sir_t sir_i,
  input  apu_vgpu_siw_t siw_i,
  input  apu_vgpu_slx_t slx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_six_cpl_t cpl_o,
  output apu_vgpu_six_t six_o
);
  g6lc_apu_vgpu_six #(.Enable(Enable)) i_dut (.*);
endmodule
