// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Write QueueNotify of control queue 0 at 64'h880D0200 after the
// transfer chain is walked at avail index 2 after scene guest
// ack. The cursor queue and the scene doorbell at 64'h8800E220
// record nothing. A cancel before the beat writes nothing. This
// is later than g6lc_apu_vgpu_rnx. This is not
// g6lc_apu_vgpu_qnt, not g6lc_apu_vgpu_snt, and not
// g6lc_apu_virtio_mmio. g6lc_apu_vgpu_avail still rejects NEXT.
// The image is not kept. The compiler TEX opcode still returns
// -26. This is not Mesa glReadPixels.

// TransferNotifyAfterAck (rnt): QueueNotify of control queue 0 after that walker.
module g6lc_apu_vgpu_rnt
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  apu_vgpu_rnx_t rnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rnt_cpl_t cpl_o,
  output apu_vgpu_rnt_t rnt_o,
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
    assign rnt_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | cancel_i | req_valid_i | cpl_ready_i |
                        wr_ready_i | wr_rsp_valid_i | wr_rsp_ok_i | (|rnx_i) |
                        (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_rnt_cpl_t cpl_q;
    apu_vgpu_rnt_t rnt_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = addr_q;
    assign wr_len_o = 32'd4;
    assign wr_data_o = {224'h0, APU_VGPU_QNT_QUEUE};
    assign wr_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_rnt_cpl_t'('0);
    assign rnt_o = rnt_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rnt_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (rnt_q.valid) begin
            cpl_q.status <= APU_VGPU_RNT_FAULT;
            state_q <= Done;
          end else if (!rnx_i.valid) begin
            cpl_q.status <= APU_VGPU_RNT_EMPTY;
            state_q <= Done;
          end else if (cancel_i ||
                       rnx_i.avail_idx != APU_VGPU_TUW_IDXV ||
                       rnx_i.avail_idx == 16'd1 ||
                       rnx_i.device_idx != APU_VGPU_TUW_IDXV ||
                       rnx_i.att_addr != APU_VGPU_RAB_CMD ||
                       rnx_i.att_addr == APU_VGPU_NXC_DESC) begin
            cpl_q.status <= APU_VGPU_RNT_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_QNT_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q ||
              wr_rsp_addr_i == APU_VGPU_TXC_AVAIL || wr_rsp_addr_i == APU_VGPU_SNT_ADDR)
            bad_q <= 1'b1;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_RNT_FAULT;
          else begin
            rnt_q.valid <= 1'b1;
            rnt_q.qid <= APU_VGPU_QNT_QUEUE;
            rnt_q.avail_idx <= APU_VGPU_TUW_IDXV;
            rnt_q.addr <= APU_VGPU_QNT_ADDR;
            cpl_q.status <= APU_VGPU_RNT_OK;
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
      wr_valid_o && !wr_ready_i |=> wr_valid_o && $stable(wr_addr_o) &&
                     $stable(wr_data_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> $stable(rnt_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_RNT_OK |->
        rnt_o.valid && rnt_o.qid == APU_VGPU_QNT_QUEUE &&
        rnt_o.qid != APU_VGPU_QNT_CURSOR &&
        rnt_o.avail_idx == APU_VGPU_TUW_IDXV &&
        rnt_o.addr != APU_VGPU_TXC_AVAIL && rnt_o.addr != APU_VGPU_SNT_ADDR);
    `endif
  end
endmodule

// TransferNotifyAfterAck (rnt) enable-0 fixture: QueueNotify of control queue 0 after that walker.
module g6lc_apu_vgpu_rnt_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  apu_vgpu_rnx_t rnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_rnt_cpl_t cpl_o,
  output apu_vgpu_rnt_t rnt_o,
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
  g6lc_apu_vgpu_rnt #(.Enable(Enable)) i_dut (.*);
endmodule
