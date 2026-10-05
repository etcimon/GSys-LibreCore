// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// After scene used.idx 1 is kept, write the used-buffer interrupt
// reason 32'h1 at 64'h8800E500 and raise the pin. Ack lowers the
// pin and leaves the record. A cancel before the beat writes
// nothing. This is later than g6lc_apu_vgpu_qsz. This is not
// g6lc_apu_vgpu_qiw, not g6lc_apu_vgpu_tiw, not g6lc_apu_vgpu_viw,
// and not PLIC source 9. The image is not kept. TEX is not the
// compiler opcode. This is not Mesa glReadPixels.

// SceneUsedIrq (qsi): Scene used-buffer interrupt after that index.
module g6lc_apu_vgpu_qsi
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  logic irq_ack_i,
  input  apu_vgpu_qsz_t qsz_i,
  input  apu_vgpu_qsu_t qsu_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsi_cpl_t cpl_o,
  output apu_vgpu_qsi_t qsi_o,
  output logic irq_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign qsi_o = '0;
    assign irq_o = 1'b0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | cancel_i | irq_ack_i | req_valid_i |
                        cpl_ready_i | wr_ready_i | wr_rsp_valid_i | wr_rsp_ok_i |
                        (|qsz_i) | (|qsu_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Publish, Done } state_e;
    state_e state_q;
    apu_vgpu_qsi_cpl_t cpl_q;
    apu_vgpu_qsi_t qsi_q;
    logic irq_q, armed_q;

    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = APU_VGPU_QSI_ADDR;
    assign wr_len_o = 32'd4;
    assign wr_data_o = {224'h0, APU_VGPU_QSI_REASON};
    assign wr_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qsi_cpl_t'('0);
    assign qsi_o = qsi_q;
    assign irq_o = irq_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qsi_q <= '0;
        irq_q <= 1'b0;
        armed_q <= 1'b0;
      end else begin
        if (state_q == Publish) irq_q <= 1'b1;
        else if (irq_ack_i) irq_q <= 1'b0;
        unique case (state_q)
          Idle: if (req_valid_i && req_ready_o) begin
            if (qsi_q.valid) begin
              cpl_q.status <= APU_VGPU_QSI_FAULT;
              state_q <= Done;
            end else if (!qsz_i.valid || !qsu_i.valid) begin
              cpl_q.status <= APU_VGPU_QSI_EMPTY;
              state_q <= Done;
            end else if (cancel_i ||
                         qsz_i.used_idx != APU_VGPU_QSU_IDXV ||
                         qsz_i.used_idx == APU_VGPU_TUW_IDXV ||
                         qsz_i.elem_id != APU_VGPU_QSU_ID ||
                         qsz_i.elem_id == APU_VGPU_TUW_ID ||
                         qsu_i.elem_addr != APU_VGPU_QSU_ELEM ||
                         qsu_i.elem_addr == APU_VGPU_TUW_ELEM ||
                         qsu_i.used_idx != APU_VGPU_QSU_IDXV) begin
              cpl_q.status <= APU_VGPU_QSI_FAULT;
              state_q <= Done;
            end else state_q <= Issue;
          end
          Issue: if (cancel_i) begin
            cpl_q.status <= APU_VGPU_QSI_FAULT;
            state_q <= Done;
          end else if (wr_ready_i) state_q <= WaitRsp;
          WaitRsp: if (wr_rsp_valid_i) begin
            if (cancel_i || !wr_rsp_ok_i || wr_rsp_addr_i != APU_VGPU_QSI_ADDR ||
                wr_rsp_addr_i == APU_VGPU_TIW_ADDR ||
                qsz_i.used_idx != APU_VGPU_QSU_IDXV)
              begin
                cpl_q.status <= APU_VGPU_QSI_FAULT;
                state_q <= Done;
              end else state_q <= Publish;
          end
          Publish: begin
            qsi_q.valid <= 1'b1;
            qsi_q.reason <= APU_VGPU_QSI_REASON;
            qsi_q.used_idx <= APU_VGPU_QSU_IDXV;
            qsi_q.addr <= APU_VGPU_QSI_ADDR;
            cpl_q.status <= APU_VGPU_QSI_OK;
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
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      state_q == Issue |-> irq_o == 1'b0);
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_data_o) && $stable(wr_len_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QSI_OK |->
        qsi_o.valid && qsi_o.reason == APU_VGPU_QSI_REASON &&
        qsi_o.used_idx == APU_VGPU_QSU_IDXV &&
        qsi_o.addr == APU_VGPU_QSI_ADDR &&
        qsi_o.addr != APU_VGPU_TIW_ADDR);
    `endif
  end
endmodule

// SceneUsedIrq (qsi) enable-0 fixture: Scene used-buffer interrupt after that index.
module g6lc_apu_vgpu_qsi_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  logic irq_ack_i,
  input  apu_vgpu_qsz_t qsz_i,
  input  apu_vgpu_qsu_t qsu_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qsi_cpl_t cpl_o,
  output apu_vgpu_qsi_t qsi_o,
  output logic irq_o,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i,
  input  logic [63:0] wr_rsp_addr_i
);
  g6lc_apu_vgpu_qsi #(.Enable(Enable)) i_dut (.*);
endmodule
