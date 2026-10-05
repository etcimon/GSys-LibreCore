// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Read the scene virtq_avail.idx at 64'h8800E200 after the guest
// ack of the transfer. The word is index 1. The transfer ring at
// 64'h880D0100 and index 2 record nothing. This is later than
// g6lc_apu_vgpu_qay. This is not g6lc_apu_vgpu_qav, not
// g6lc_apu_vgpu_avail, and not g6lc_apu_vgpu_nxc.
// g6lc_apu_vgpu_avail still rejects NEXT. The image is not kept.
// The compiler TEX opcode still returns -26. This is not Mesa
// glReadPixels.

// SceneAvailIdx (qsv): Scene virtq_avail.idx 1 after that ack.
module g6lc_apu_vgpu_qsv
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qay_t qay_i,
  input  apu_vgpu_qnx_t qnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsv_cpl_t cpl_o,
  output apu_vgpu_qsv_t qsv_o,
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
    assign qsv_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | req_valid_i | cpl_ready_i | rd_ready_i |
                        rd_rsp_valid_i | rd_rsp_ok_i | (|qay_i) | (|qnx_i) |
                        (|rd_rsp_addr_i) | (|rd_rsp_len_i) | (|rd_rsp_data_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_qsv_cpl_t cpl_q;
    apu_vgpu_qsv_t qsv_q;
    logic [15:0] idx_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign rd_valid_o = state_q == Issue;
    assign rd_addr_o = addr_q;
    assign rd_len_o = 32'd4;
    assign rd_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qsv_cpl_t'('0);
    assign qsv_o = qsv_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qsv_q <= '0;
        idx_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qsv_q.valid) begin
            cpl_q.status <= APU_VGPU_QSV_FAULT;
            state_q <= Done;
          end else if (!qay_i.valid || !qnx_i.valid) begin
            cpl_q.status <= APU_VGPU_QSV_EMPTY;
            state_q <= Done;
          end else if (qay_i.ack != APU_VGPU_TIW_REASON ||
                       qay_i.remain != APU_VGPU_VAW_CLEAR ||
                       qay_i.used_idx != APU_VGPU_TUW_IDXV ||
                       qay_i.used_idx == APU_VGPU_QSV_IDXV ||
                       qnx_i.qid != APU_VGPU_QNT_QUEUE ||
                       qnx_i.qid == APU_VGPU_QNT_CURSOR ||
                       qnx_i.avail_idx != APU_VGPU_TUW_IDXV) begin
            cpl_q.status <= APU_VGPU_QSV_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_QSV_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (rd_ready_i) state_q <= WaitRsp;
        WaitRsp: if (rd_rsp_valid_i) begin
          if (!rd_rsp_ok_i || rd_rsp_addr_i != addr_q ||
              rd_rsp_addr_i == APU_VGPU_QAV_ADDR ||
              rd_rsp_len_i != 32'd4 ||
              rd_rsp_data_i[31:0] != APU_VGPU_QSV_WORD ||
              rd_rsp_data_i[31:0] == APU_VGPU_QAV_WORD ||
              rd_rsp_data_i[31:16] != APU_VGPU_QSV_IDXV ||
              rd_rsp_data_i[31:16] == APU_VGPU_TUW_IDXV)
            bad_q <= 1'b1;
          idx_q <= rd_rsp_data_i[31:16];
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_QSV_FAULT;
          else begin
            qsv_q.valid <= 1'b1;
            qsv_q.avail_idx <= idx_q;
            qsv_q.addr <= APU_VGPU_QSV_ADDR;
            cpl_q.status <= APU_VGPU_QSV_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qsv_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QSV_OK |->
        qsv_o.valid && qsv_o.avail_idx == APU_VGPU_QSV_IDXV &&
        qsv_o.addr == APU_VGPU_QSV_ADDR &&
        qsv_o.addr != APU_VGPU_QAV_ADDR);
    `endif
  end
endmodule

// SceneAvailIdx (qsv) enable-0 fixture: Scene virtq_avail.idx 1 after that ack.
module g6lc_apu_vgpu_qsv_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_vgpu_qay_t qay_i,
  input  apu_vgpu_qnx_t qnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsv_cpl_t cpl_o,
  output apu_vgpu_qsv_t qsv_o,
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
  g6lc_apu_vgpu_qsv #(.Enable(Enable)) i_dut (.*);
endmodule
