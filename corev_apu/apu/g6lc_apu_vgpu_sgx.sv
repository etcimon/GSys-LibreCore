// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Ack 32'h1 and remain 0 with used.idx 1 after QueueNotify. The
// transfer ack at 64'h880C0010 and index 2 record nothing. This
// is later than g6lc_apu_vgpu_sgk. This is not
// g6lc_apu_vgpu_qgx, not g6lc_apu_vgpu_qay, and not
// g6lc_apu_vgpu_vak. TEX is not the compiler opcode. This is not
// Mesa glReadPixels.

// SceneAckAfterNotifyCheck (sgx): Ack 32'h1 and remain 0 after scene interrupt after notify.
module g6lc_apu_vgpu_sgx
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sgk_t sgk_i,
  input  apu_vgpu_sga_t sga_i,
  input  apu_vgpu_six_t six_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sgx_cpl_t cpl_o,
  output apu_vgpu_sgx_t sgx_o
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign sgx_o = '0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i |
                        (|sgk_i) | (|sga_i) | (|six_i);
  end else begin : gen_on
    typedef enum logic { Idle, Done } state_e;
    state_e state_q;
    apu_vgpu_sgx_cpl_t cpl_q;
    apu_vgpu_sgx_t sgx_q;
    logic armed_q;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_sgx_cpl_t'('0);
    assign sgx_o = sgx_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        sgx_q <= '0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (sgx_q.valid) begin
            cpl_q.status <= APU_VGPU_SGX_FAULT;
          end else if (!sgk_i.valid || !sga_i.valid || !six_i.valid) begin
            cpl_q.status <= APU_VGPU_SGX_EMPTY;
          end else if (sgk_i.ack != APU_VGPU_QSI_REASON ||
                       sgk_i.remain != APU_VGPU_VAW_CLEAR ||
                       sgk_i.used_idx != APU_VGPU_QSU_IDXV ||
                       sgk_i.used_idx == APU_VGPU_TUW_IDXV ||
                       sgk_i.ack == sgk_i.remain ||
                       sgk_i.ack_addr != APU_VGPU_QGA_ADDR ||
                       sgk_i.ack_addr == APU_VGPU_TAW_ADDR ||
                       sgk_i.status_addr != APU_VGPU_QGA_STAT ||
                       sgk_i.ack != sga_i.ack ||
                       sgk_i.remain != sga_i.remain ||
                       six_i.used_idx != APU_VGPU_QSU_IDXV) begin
            cpl_q.status <= APU_VGPU_SGX_FAULT;
          end else begin
            sgx_q.valid <= 1'b1;
            sgx_q.ack <= sgk_i.ack;
            sgx_q.remain <= sgk_i.remain;
            sgx_q.used_idx <= sgk_i.used_idx;
            cpl_q.status <= APU_VGPU_SGX_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(sgx_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SGX_OK |->
        sgx_o.valid && sgx_o.ack == APU_VGPU_QSI_REASON &&
        sgx_o.remain == APU_VGPU_VAW_CLEAR &&
        sgx_o.used_idx == APU_VGPU_QSU_IDXV);
    `endif
  end
endmodule

// SceneAckAfterNotifyCheck (sgx) enable-0 fixture: Ack 32'h1 and remain 0 after scene interrupt after notify.
module g6lc_apu_vgpu_sgx_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_sgk_t sgk_i,
  input  apu_vgpu_sga_t sga_i,
  input  apu_vgpu_six_t six_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sgx_cpl_t cpl_o,
  output apu_vgpu_sgx_t sgx_o
);
  g6lc_apu_vgpu_sgx #(.Enable(Enable)) i_dut (.*);
endmodule
