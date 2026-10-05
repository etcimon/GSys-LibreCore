// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the scene used-buffer interrupt reason at 64'h8800E500
// after QueueNotify. The low word is 32'h1. The transfer status
// word at 64'h880C0000 records nothing. The pin may already have
// been acknowledged. This is later than g6lc_apu_vgpu_siw. This
// is not g6lc_apu_vgpu_qsn, not g6lc_apu_vgpu_qir, and not
// g6lc_apu_vgpu_vir. The image is not kept. TEX is not the
// compiler opcode. This is not Mesa glReadPixels.

// SceneIrqAfterNotifyKeep (sir): Guest keep of that scene interrupt reason.
module g6lc_apu_vgpu_sir
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_siw_t siw_i,
  input  apu_vgpu_slx_t slx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sir_cpl_t cpl_o,
  output apu_vgpu_sir_t sir_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign sir_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|siw_i) | (|slx_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_sir_cpl_t cpl_q;
    apu_vgpu_sir_t sir_q;
    logic [31:0] reason_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = APU_VGPU_QSI_ADDR;
    assign rd_len_o = 32'd4;
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_sir_cpl_t'('0);
    assign sir_o = sir_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        sir_q <= '0;
        reason_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (sir_q.valid) begin
            cpl_q.status <= APU_VGPU_SIR_FAULT;
            state_q <= Done;
          end else if (!siw_i.valid || !slx_i.valid) begin
            cpl_q.status <= APU_VGPU_SIR_EMPTY;
            state_q <= Done;
          end else if (siw_i.reason != APU_VGPU_QSI_REASON ||
                       siw_i.used_idx != APU_VGPU_QSU_IDXV ||
                       siw_i.used_idx == APU_VGPU_TUW_IDXV ||
                       siw_i.addr != APU_VGPU_QSI_ADDR ||
                       siw_i.addr == APU_VGPU_TIW_ADDR ||
                       slx_i.used_idx != APU_VGPU_QSU_IDXV) begin
            cpl_q.status <= APU_VGPU_SIR_FAULT;
            state_q <= Done;
          end else begin
            reason_q <= '0;
            bad_q <= 1'b0;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != APU_VGPU_QSI_ADDR ||
                    rd_rsp_addr_i == APU_VGPU_TIW_ADDR ||
                    rd_rsp_len_i != 32'd4 ||
                    rd_rsp_data_i[31:0] != APU_VGPU_QSI_REASON;
          if (bad_bus) bad_q <= 1'b1;
          else reason_q <= rd_rsp_data_i[31:0];
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q || reason_q != APU_VGPU_QSI_REASON ||
              reason_q != siw_i.reason)
            cpl_q.status <= APU_VGPU_SIR_FAULT;
          else begin
            sir_q.valid <= 1'b1;
            sir_q.reason <= reason_q;
            sir_q.used_idx <= siw_i.used_idx;
            sir_q.addr <= APU_VGPU_QSI_ADDR;
            cpl_q.status <= APU_VGPU_SIR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(sir_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SIR_OK |->
        sir_o.valid && sir_o.reason == APU_VGPU_QSI_REASON &&
        sir_o.used_idx == APU_VGPU_QSU_IDXV &&
        sir_o.addr != APU_VGPU_TIW_ADDR);
    `endif
  end
endmodule

// SceneIrqAfterNotifyKeep (sir) enable-0 fixture: Guest keep of that scene interrupt reason.
module g6lc_apu_vgpu_sir_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_siw_t siw_i,
  input  apu_vgpu_slx_t slx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_sir_cpl_t cpl_o,
  output apu_vgpu_sir_t sir_o,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i
);
  g6lc_apu_vgpu_sir #(.Enable(Enable)) i_dut (.*);
endmodule
