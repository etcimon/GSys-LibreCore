// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Write QueueNotify of control queue 0 at 64'h880D0200 after the
// transfer chain is walked at avail index 2. The cursor queue
// records nothing. A cancel before the beat writes nothing. This
// is later than g6lc_apu_vgpu_tnx. This is not
// g6lc_apu_virtio_mmio. g6lc_apu_vgpu_avail still rejects NEXT.
// The image is not kept. The compiler TEX opcode still returns
// -26. This is not Mesa glReadPixels.

// TransferQueueNotify (qnt): Guest QueueNotify of the 64 by 64 transfer.
// Interplay: TransferNextWalk (tnw) <-> TransferQueueNotify (qnt) ==> 64'h880D0200. See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_qnt
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  apu_vgpu_tnx_t tnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qnt_cpl_t cpl_o,
  output apu_vgpu_qnt_t qnt_o,
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
    assign qnt_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | cancel_i | req_valid_i | cpl_ready_i |
                        wr_ready_i | wr_rsp_valid_i | wr_rsp_ok_i | (|tnx_i) |
                        (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_qnt_cpl_t cpl_q;
    apu_vgpu_qnt_t qnt_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = addr_q;
    assign wr_len_o = 32'd4;
    assign wr_data_o = {224'h0, APU_VGPU_QNT_QUEUE};
    assign wr_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_qnt_cpl_t'('0);
    assign qnt_o = qnt_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        qnt_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (qnt_q.valid) begin
            cpl_q.status <= APU_VGPU_QNT_FAULT;
            state_q <= Done;
          end else if (!tnx_i.valid) begin
            cpl_q.status <= APU_VGPU_QNT_EMPTY;
            state_q <= Done;
          end else if (cancel_i ||
                       tnx_i.avail_idx != APU_VGPU_TUW_IDXV ||
                       tnx_i.avail_idx == 16'd1 ||
                       tnx_i.device_idx != APU_VGPU_TUW_IDXV ||
                       tnx_i.att_addr != APU_VGPU_RAB_CMD ||
                       tnx_i.att_addr == APU_VGPU_NXC_DESC) begin
            cpl_q.status <= APU_VGPU_QNT_FAULT;
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
              wr_rsp_addr_i == APU_VGPU_TXC_AVAIL)
            bad_q <= 1'b1;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_QNT_FAULT;
          else begin
            qnt_q.valid <= 1'b1;
            qnt_q.qid <= APU_VGPU_QNT_QUEUE;
            qnt_q.avail_idx <= APU_VGPU_TUW_IDXV;
            qnt_q.addr <= APU_VGPU_QNT_ADDR;
            cpl_q.status <= APU_VGPU_QNT_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(qnt_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_QNT_OK |->
        qnt_o.valid && qnt_o.qid == APU_VGPU_QNT_QUEUE &&
        qnt_o.qid != APU_VGPU_QNT_CURSOR &&
        qnt_o.avail_idx == APU_VGPU_TUW_IDXV &&
        qnt_o.addr != APU_VGPU_TXC_AVAIL);
    `endif
  end
endmodule

// TransferQueueNotify (qnt) enable-0 fixture: Guest QueueNotify of the 64 by 64 transfer.
module g6lc_apu_vgpu_qnt_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  apu_vgpu_tnx_t tnx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_qnt_cpl_t cpl_o,
  output apu_vgpu_qnt_t qnt_o,
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
  g6lc_apu_vgpu_qnt #(.Enable(Enable)) i_dut (.*);
endmodule
