// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// After used.idx 2 is kept, write the used-buffer interrupt reason
// 32'h1 at 64'h880C0000 and raise the pin. Ack lowers the pin and
// leaves the record. A cancel before the beat writes nothing. This
// is later than g6lc_apu_vgpu_tux. This is not g6lc_apu_vgpu_viw
// and not PLIC source 9. The image is not kept. TEX is not the
// compiler opcode. This is not Mesa glReadPixels.

// TransferIrq (tiw): Used-buffer interrupt of the 64 by 64 transfer.
module g6lc_apu_vgpu_tiw
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  logic irq_ack_i,
  input  apu_vgpu_tux_t tux_i,
  input  apu_vgpu_tuw_t tuw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tiw_cpl_t cpl_o,
  output apu_vgpu_tiw_t tiw_o,
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
    assign tiw_o = '0;
    assign irq_o = 1'b0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | cancel_i | irq_ack_i | req_valid_i |
                        cpl_ready_i | wr_ready_i | wr_rsp_valid_i | wr_rsp_ok_i |
                        (|tux_i) | (|tuw_i) | (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Publish, Done } state_e;
    state_e state_q;
    apu_vgpu_tiw_cpl_t cpl_q;
    apu_vgpu_tiw_t tiw_q;
    logic irq_q, armed_q;

    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = APU_VGPU_TIW_ADDR;
    assign wr_len_o = 32'd4;
    assign wr_data_o = {224'h0, APU_VGPU_TIW_REASON};
    assign wr_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_tiw_cpl_t'('0);
    assign tiw_o = tiw_q;
    assign irq_o = irq_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        tiw_q <= '0;
        irq_q <= 1'b0;
        armed_q <= 1'b0;
      end else begin
        if (state_q == Publish) irq_q <= 1'b1;
        else if (irq_ack_i) irq_q <= 1'b0;
        unique case (state_q)
          Idle: if (req_valid_i && req_ready_o) begin
            if (tiw_q.valid) begin
              cpl_q.status <= APU_VGPU_TIW_FAULT;
              state_q <= Done;
            end else if (!tux_i.valid || !tuw_i.valid) begin
              cpl_q.status <= APU_VGPU_TIW_EMPTY;
              state_q <= Done;
            end else if (cancel_i ||
                         tux_i.used_idx != APU_VGPU_TUW_IDXV ||
                         tux_i.used_idx == 16'd1 ||
                         tux_i.elem_id != APU_VGPU_TUW_ID ||
                         tux_i.elem_id == 32'd0 ||
                         tuw_i.elem_addr != APU_VGPU_TUW_ELEM ||
                         tuw_i.elem_addr == APU_VGPU_GCW_ELEM ||
                         tuw_i.used_idx != APU_VGPU_TUW_IDXV) begin
              cpl_q.status <= APU_VGPU_TIW_FAULT;
              state_q <= Done;
            end else state_q <= Issue;
          end
          Issue: if (cancel_i) begin
            cpl_q.status <= APU_VGPU_TIW_FAULT;
            state_q <= Done;
          end else if (wr_ready_i) state_q <= WaitRsp;
          WaitRsp: if (wr_rsp_valid_i) begin
            if (cancel_i || !wr_rsp_ok_i || wr_rsp_addr_i != APU_VGPU_TIW_ADDR ||
                wr_rsp_addr_i == APU_VGPU_VIW_ADDR ||
                tux_i.used_idx != APU_VGPU_TUW_IDXV)
              begin
                cpl_q.status <= APU_VGPU_TIW_FAULT;
                state_q <= Done;
              end else state_q <= Publish;
          end
          Publish: begin
            tiw_q.valid <= 1'b1;
            tiw_q.reason <= APU_VGPU_TIW_REASON;
            tiw_q.used_idx <= APU_VGPU_TUW_IDXV;
            tiw_q.addr <= APU_VGPU_TIW_ADDR;
            cpl_q.status <= APU_VGPU_TIW_OK;
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
      cpl_valid_o && cpl_o.status == APU_VGPU_TIW_OK |->
        tiw_o.valid && tiw_o.reason == APU_VGPU_TIW_REASON &&
        tiw_o.used_idx == APU_VGPU_TUW_IDXV &&
        tiw_o.addr == APU_VGPU_TIW_ADDR &&
        tiw_o.addr != APU_VGPU_VIW_ADDR);
    `endif
  end
endmodule

// TransferIrq (tiw) enable-0 fixture: Used-buffer interrupt of the 64 by 64 transfer.
module g6lc_apu_vgpu_tiw_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  logic irq_ack_i,
  input  apu_vgpu_tux_t tux_i,
  input  apu_vgpu_tuw_t tuw_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_tiw_cpl_t cpl_o,
  output apu_vgpu_tiw_t tiw_o,
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
  g6lc_apu_vgpu_tiw #(.Enable(Enable)) i_dut (.*);
endmodule
