// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Reason 32'h1 at 64'h880C0000 with used.idx 2 after the guest
// used ring. The scene status word at 64'h8800E500 records
// nothing. Index 1 records nothing. This is later than
// g6lc_apu_vgpu_qir. This is not g6lc_apu_vgpu_tix and not
// g6lc_apu_vgpu_vik. The pin is not kept. TEX is not the compiler
// opcode. This is not Mesa glReadPixels.

// TransferUsedIrqCheck (qix): Reason 32'h1 after the guest used ring.
module g6lc_apu_vgpu_qix
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qir_t qir_i,
  input  apu_vgpu_qiw_t qiw_i,
  input  apu_vgpu_qux_t qux_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qix_cpl_t cpl_o,
  output apu_vgpu_qix_t qix_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qix_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|qir_i) | (|qiw_i) | (|qux_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_qix_cpl_t cpl_q;
    apu_vgpu_qix_t qix_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qix_cpl_t'('0);
    assign qix_o = qix_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qix_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qix_q.valid) begin
            cpl_q.status <= APU_VGPU_QIX_FAULT;
          end else if (!qir_i.valid || !qiw_i.valid || !qux_i.valid) begin
            cpl_q.status <= APU_VGPU_QIX_EMPTY;
          end else if (qir_i.reason != APU_VGPU_TIW_REASON ||
                       qir_i.used_idx != APU_VGPU_TUW_IDXV ||
                       qir_i.used_idx == 16'd1 ||
                       qir_i.addr != APU_VGPU_TIW_ADDR ||
                       qir_i.addr == APU_VGPU_VIW_ADDR ||
                       qir_i.reason != qiw_i.reason ||
                       qir_i.used_idx != qiw_i.used_idx ||
                       qux_i.used_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_QIX_FAULT;
          end else begin
            qix_q.valid <= 1'b1;
            qix_q.reason <= qir_i.reason;
            qix_q.used_idx <= qir_i.used_idx;
            qix_q.addr <= qir_i.addr;
            cpl_q.status <= APU_VGPU_QIX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qix_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QIX_OK |->
        qix_o.valid && qix_o.reason == APU_VGPU_TIW_REASON &&
        qix_o.used_idx == APU_VGPU_TUW_IDXV &&
        qix_o.addr != APU_VGPU_VIW_ADDR);
    `endif
  end
endmodule

// TransferUsedIrqCheck (qix) enable-0 fixture: Reason 32'h1 after the guest used ring.
module g6lc_apu_vgpu_qix_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qir_t qir_i,
  input  apu_vgpu_qiw_t qiw_i,
  input  apu_vgpu_qux_t qux_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qix_cpl_t cpl_o,
  output apu_vgpu_qix_t qix_o
);
  g6lc_apu_vgpu_qix #(.Enable(Enable)) i_dut (.*);
endmodule
