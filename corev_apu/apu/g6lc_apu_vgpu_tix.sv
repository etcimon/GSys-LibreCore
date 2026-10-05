// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Reason 32'h1 at 64'h880C0000 with used.idx 2. The scene status
// word at 64'h8800E500 records nothing. Index 1 records nothing.
// This is later than g6lc_apu_vgpu_tir. This is not
// g6lc_apu_vgpu_vik. The pin is not kept. TEX is not the compiler
// opcode. This is not Mesa glReadPixels.

// TransferIrqCheck (tix): Reason 32'h1 at 64'h880C0000, not the scene status word.
module g6lc_apu_vgpu_tix
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tir_t tir_i,
  input  apu_vgpu_tiw_t tiw_i,
  input  apu_vgpu_tux_t tux_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tix_cpl_t cpl_o,
  output apu_vgpu_tix_t tix_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign tix_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|tir_i) | (|tiw_i) | (|tux_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_tix_cpl_t cpl_q;
    apu_vgpu_tix_t tix_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tix_cpl_t'('0);
    assign tix_o = tix_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tix_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (tix_q.valid) begin
            cpl_q.status <= APU_VGPU_TIX_FAULT;
          end else if (!tir_i.valid || !tiw_i.valid || !tux_i.valid) begin
            cpl_q.status <= APU_VGPU_TIX_EMPTY;
          end else if (tir_i.reason != APU_VGPU_TIW_REASON ||
                       tir_i.used_idx != APU_VGPU_TUW_IDXV ||
                       tir_i.used_idx == 16'd1 ||
                       tir_i.addr != APU_VGPU_TIW_ADDR ||
                       tir_i.addr == APU_VGPU_VIW_ADDR ||
                       tir_i.reason != tiw_i.reason ||
                       tir_i.used_idx != tiw_i.used_idx ||
                       tux_i.used_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_TIX_FAULT;
          end else begin
            tix_q.valid <= 1'b1;
            tix_q.reason <= tir_i.reason;
            tix_q.used_idx <= tir_i.used_idx;
            tix_q.addr <= tir_i.addr;
            cpl_q.status <= APU_VGPU_TIX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(tix_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_TIX_OK |->
        tix_o.valid && tix_o.reason == APU_VGPU_TIW_REASON &&
        tix_o.used_idx == APU_VGPU_TUW_IDXV &&
        tix_o.addr != APU_VGPU_VIW_ADDR);
    `endif
  end
endmodule

// TransferIrqCheck (tix) enable-0 fixture: Reason 32'h1 at 64'h880C0000, not the scene status word.
module g6lc_apu_vgpu_tix_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_tir_t tir_i,
  input  apu_vgpu_tiw_t tiw_i,
  input  apu_vgpu_tux_t tux_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tix_cpl_t cpl_o,
  output apu_vgpu_tix_t tix_o
);
  g6lc_apu_vgpu_tix #(.Enable(Enable)) i_dut (.*);
endmodule
