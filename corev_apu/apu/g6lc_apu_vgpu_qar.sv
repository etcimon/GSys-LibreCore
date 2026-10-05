// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the guest ack at 64'h880C0010 and the cleared status at
// 64'h880C0000. The ack low word stays 32'h1. The status low word
// is 32'h0. The scene ack at 64'h8800E510 records nothing. This is
// later than g6lc_apu_vgpu_qaw. This is not g6lc_apu_vgpu_tar and not g6lc_apu_vgpu_var.
// The image is not kept. TEX is not the compiler opcode. This is
// not Mesa glReadPixels.

// TransferUsedAckRead (qar): Guest read of that ack and remain.
module g6lc_apu_vgpu_qar
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qaw_t qaw_i,
  input  apu_vgpu_qix_t qix_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qar_cpl_t cpl_o,
  output apu_vgpu_qar_t qar_o,
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
    assign qar_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|qaw_i) | (|qix_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_qar_cpl_t cpl_q;
    apu_vgpu_qar_t qar_q;
    logic beat_q;
    logic [31:0] ack_q, remain_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'd4;
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qar_cpl_t'('0);
    assign qar_o = qar_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qar_q <= '0;
        beat_q <= 1'b0;
        ack_q <= '0;
        remain_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qar_q.valid) begin
            cpl_q.status <= APU_VGPU_QAR_FAULT;
            state_q <= Done;
          end else if (!qaw_i.valid || !qix_i.valid) begin
            cpl_q.status <= APU_VGPU_QAR_EMPTY;
            state_q <= Done;
          end else if (qaw_i.ack != APU_VGPU_TIW_REASON ||
                       qaw_i.remain != APU_VGPU_VAW_CLEAR ||
                       qaw_i.used_idx != APU_VGPU_TUW_IDXV ||
                       qaw_i.used_idx == 16'd1 ||
                       qaw_i.ack_addr != APU_VGPU_TAW_ADDR ||
                       qaw_i.ack_addr == APU_VGPU_VAW_ADDR ||
                       qaw_i.status_addr != APU_VGPU_TIW_ADDR ||
                       qaw_i.status_addr == APU_VGPU_VIW_ADDR ||
                       qix_i.used_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_QAR_FAULT;
            state_q <= Done;
          end else begin
            beat_q <= 1'b0;
            ack_q <= '0;
            remain_q <= '0;
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_TAW_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          logic bad_bus;
          logic [31:0] want;
          want = beat_q == 1'b0 ? APU_VGPU_TIW_REASON : APU_VGPU_VAW_CLEAR;
          bad_bus = !rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
                    rd_rsp_len_i != 32'd4 || rd_rsp_data_i[31:0] != want;
          if (bad_bus) begin
            bad_q <= 1'b1;
            state_q <= Commit;
          end else if (beat_q == 1'b0) begin
            ack_q <= rd_rsp_data_i[31:0];
            beat_q <= 1'b1;
            addr_q <= APU_VGPU_TIW_ADDR;
            state_q <= Issue;
          end else begin
            remain_q <= rd_rsp_data_i[31:0];
            state_q <= Commit;
          end
        end
        Commit: begin
          if (bad_q || beat_q != 1'b1 || ack_q != APU_VGPU_TIW_REASON ||
              remain_q != APU_VGPU_VAW_CLEAR || ack_q == remain_q)
            cpl_q.status <= APU_VGPU_QAR_FAULT;
          else begin
            qar_q.valid <= 1'b1;
            qar_q.ack <= ack_q;
            qar_q.remain <= remain_q;
            qar_q.used_idx <= qaw_i.used_idx;
            qar_q.ack_addr <= APU_VGPU_TAW_ADDR;
            qar_q.status_addr <= APU_VGPU_TIW_ADDR;
            cpl_q.status <= APU_VGPU_QAR_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qar_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QAR_OK |->
        qar_o.valid && qar_o.ack == APU_VGPU_TIW_REASON &&
        qar_o.remain == APU_VGPU_VAW_CLEAR &&
        qar_o.used_idx == APU_VGPU_TUW_IDXV &&
        qar_o.ack_addr != APU_VGPU_VAW_ADDR);
    `endif
  end
endmodule

// TransferUsedAckRead (qar) enable-0 fixture: Guest read of that ack and remain.
module g6lc_apu_vgpu_qar_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qaw_t qaw_i,
  input  apu_vgpu_qix_t qix_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qar_cpl_t cpl_o,
  output apu_vgpu_qar_t qar_o,
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
  g6lc_apu_vgpu_qar #(.Enable(Enable)) i_dut (.*);
endmodule
