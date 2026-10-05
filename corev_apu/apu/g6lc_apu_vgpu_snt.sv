// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Write QueueNotify of control queue 0 at 64'h8800E220 after the
// scene chain is walked at avail index 1. The cursor queue and
// the transfer doorbell record nothing. A cancel before the beat
// writes nothing. This is later than g6lc_apu_vgpu_snx. This is
// not g6lc_apu_vgpu_qnt and not g6lc_apu_virtio_mmio. g6lc_apu_vgpu_avail still rejects NEXT.
// The image is not kept. The compiler TEX opcode still returns
// -26. This is not Mesa glReadPixels.

// SceneQueueNotify (snt): Scene QueueNotify after that walker.
// Interplay: SceneNextWalk (snw) <-> SceneQueueNotify (snt) ==> 64'h8800E220. See AGENTS-impl-interplays.md.
module g6lc_apu_vgpu_snt
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  apu_vgpu_snx_t snx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_snt_cpl_t cpl_o,
  output apu_vgpu_snt_t snt_o,
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
    assign snt_o = '0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused_req;
    assign unused_req = clk_i | rst_ni | cancel_i | req_valid_i | cpl_ready_i |
                        wr_ready_i | wr_rsp_valid_i | wr_rsp_ok_i | (|snx_i) |
                        (|wr_rsp_addr_i);
  end else begin : gen_on
    typedef enum logic [2:0] { Idle, Issue, WaitRsp, Commit, Done } state_e;
    state_e state_q;
    apu_vgpu_snt_cpl_t cpl_q;
    apu_vgpu_snt_t snt_q;
    logic [63:0] addr_q;
    logic bad_q, armed_q;

    assign wr_valid_o = state_q == Issue;
    assign wr_addr_o = addr_q;
    assign wr_len_o = 32'd4;
    assign wr_data_o = {224'h0, APU_VGPU_QNT_QUEUE};
    assign wr_rsp_ready_o = state_q == WaitRsp;
    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vgpu_snt_cpl_t'('0);
    assign snt_o = snt_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        snt_q <= '0;
        addr_q <= '0;
        bad_q <= 1'b0;
        armed_q <= 1'b0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          if (snt_q.valid) begin
            cpl_q.status <= APU_VGPU_SNT_FAULT;
            state_q <= Done;
          end else if (!snx_i.valid) begin
            cpl_q.status <= APU_VGPU_SNT_EMPTY;
            state_q <= Done;
          end else if (cancel_i ||
                       snx_i.avail_idx != APU_VGPU_QSU_IDXV ||
                       snx_i.avail_idx == APU_VGPU_TUW_IDXV ||
                       snx_i.device_idx != APU_VGPU_QSU_IDXV ||
                       snx_i.att_addr != APU_VGPU_HDR_ADDR ||
                       snx_i.att_addr == APU_VGPU_RAB_CMD) begin
            cpl_q.status <= APU_VGPU_SNT_FAULT;
            state_q <= Done;
          end else begin
            bad_q <= 1'b0;
            addr_q <= APU_VGPU_SNT_ADDR;
            state_q <= Issue;
          end
        end
        Issue: if (wr_ready_i) state_q <= WaitRsp;
        WaitRsp: if (wr_rsp_valid_i) begin
          if (!wr_rsp_ok_i || wr_rsp_addr_i != addr_q ||
              wr_rsp_addr_i == APU_VGPU_QNT_ADDR)
            bad_q <= 1'b1;
          state_q <= Commit;
        end
        Commit: begin
          if (bad_q)
            cpl_q.status <= APU_VGPU_SNT_FAULT;
          else begin
            snt_q.valid <= 1'b1;
            snt_q.qid <= APU_VGPU_QNT_QUEUE;
            snt_q.avail_idx <= APU_VGPU_QSU_IDXV;
            snt_q.addr <= APU_VGPU_SNT_ADDR;
            cpl_q.status <= APU_VGPU_SNT_OK;
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
      cpl_valid_o && !cpl_ready_i |=> $stable(snt_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && cpl_o.status == APU_VGPU_SNT_OK |->
        snt_o.valid && snt_o.qid == APU_VGPU_QNT_QUEUE &&
        snt_o.qid != APU_VGPU_QNT_CURSOR &&
        snt_o.avail_idx == APU_VGPU_QSU_IDXV &&
        snt_o.addr != APU_VGPU_QNT_ADDR);
    `endif
  end
endmodule

// SceneQueueNotify (snt) enable-0 fixture: Scene QueueNotify after that walker.
module g6lc_apu_vgpu_snt_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cancel_i,
  input  apu_vgpu_snx_t snx_i,
  input  logic req_valid_i,
  output logic req_ready_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vgpu_snt_cpl_t cpl_o,
  output apu_vgpu_snt_t snt_o,
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
  g6lc_apu_vgpu_snt #(.Enable(Enable)) i_dut (.*);
endmodule
