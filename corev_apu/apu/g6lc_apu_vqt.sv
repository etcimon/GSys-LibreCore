// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// virtio vq_state[0] supplies desc/avail/used/num and arms NotifyTake
// on notify_pending[0]. A doorbell with ready=0 faults and still
// clears. Cursor pending[1] is forwarded after the queue is armed.
// CFG still fires through NotifyTake. Enable=0 elaborates no
// datapath. Does not edit virtio_mmio, g6lc_apu_vgpu_avail, or
// g6lc_apu_sys. FeatureVirgl stays illegal. ApuCfg.NumCapsets
// stays 0.

// VqTake (vqt): virtio vq_state[0] arms NotifyTake on notify_pending[0]. Default-off. FeatureVirgl stays illegal.
// Interplay: VqTake (vqt) --> NotifyTake (ntk). --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_vqt
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vqt_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  apu_vq_state_t vq0_i,
  input  apu_vq_state_t vq1_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vqt_cpl_t cpl_o,
  output apu_vqt_t vqt_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i
);
  if (!Enable) begin : gen_off
    assign req_ready_o = 1'b0;
    assign notify_clear_o = '0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign vqt_o = '0;
    assign irq_o = 1'b0;
    assign isr_o = '0;
    assign rd_valid_o = 1'b0;
    assign rd_addr_o = '0;
    assign rd_len_o = '0;
    assign rd_rsp_ready_o = 1'b0;
    assign wr_valid_o = 1'b0;
    assign wr_addr_o = '0;
    assign wr_len_o = '0;
    assign wr_data_o = '0;
    assign wr_rsp_ready_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | req_valid_i | cpl_ready_i | ack_valid_i |
                    rd_ready_i | rd_rsp_valid_i | rd_rsp_ok_i | wr_ready_i |
                    wr_rsp_valid_i | wr_rsp_ok_i | (|req_i) | (|in_a_i) |
                    (|in_b_i) | (|ack_i) | (|rd_rsp_addr_i) | (|rd_rsp_len_i) |
                    (|rd_rsp_data_i) | (|notify_pending_i) |
                    (|vq0_i) | (|vq1_i);
  end else begin : gen_on
    typedef enum logic [2:0] {
      Idle, FireArm, WaitArm, FireReq, WaitNtk, Clr, Done
    } state_e;
    state_e state_q;
    apu_vqt_cpl_t cpl_q;
    apu_vqt_t rec_q;
    apu_vqt_req_t req_q;
    apu_vq_state_t snap_q;
    logic armed_q;
    logic [APU_NUM_QUEUES-1:0] clr_q, ntk_pend, ntk_clr;
    logic vq_ok, need_arm;
    logic ntk_req_v, ntk_rdy, ntk_cpl, ntk_ack, ntk_irq;
    logic [31:0] ntk_isr;
    apu_ntk_req_t ntk_req, arm_req;
    apu_ntk_cpl_t ntk_c;
    apu_ntk_t ntk_rec;

    assign req_ready_o = state_q == Idle && rst_ni && ntk_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vqt_cpl_t'('0);
    assign vqt_o = rec_q;
    assign irq_o = ntk_irq;
    assign isr_o = ntk_isr;
    assign notify_clear_o = (state_q == Clr) ? clr_q : ntk_clr;
    assign ntk_req_v = (state_q == FireArm) || (state_q == FireReq);
    assign ntk_ack = (state_q == WaitArm) || (state_q == WaitNtk);
    assign ntk_pend = (state_q == WaitNtk) ? notify_pending_i : '0;
    assign vq_ok = vq0_i.ready && apu_queue_cfg_ok(vq0_i) &&
                   (vq0_i.num >= 16'd2) &&
                   (vq0_i.num <= 16'(APU_CHAIN_QMAX));
    assign need_arm = !armed_q ||
                      (snap_q.desc != vq0_i.desc) ||
                      (snap_q.avail != vq0_i.avail) ||
                      (snap_q.used != vq0_i.used) ||
                      (snap_q.num != vq0_i.num);
    always_comb begin
      arm_req = '0;
      arm_req.arm = 1'b1;
      arm_req.qpu.vct.op = APU_VCT_NOTIFY;
      arm_req.qpu.vct.qty.qrn.avu.avail_base = vq0_i.avail;
      arm_req.qpu.vct.qty.qrn.avu.desc_base = vq0_i.desc;
      arm_req.qpu.vct.qty.qrn.avu.used_base = vq0_i.used;
      arm_req.qpu.vct.qty.qrn.avu.queue_size = vq0_i.num[7:0];
      arm_req.qpu.vct.qty.qrn.avu.max_chain = 4'd8;
      ntk_req = (state_q == FireArm) ? arm_req : req_q.ntk;
    end

    g6lc_apu_ntk #(.Enable(1'b1)) i_ntk (
      .clk_i, .rst_ni,
      .req_valid_i(ntk_req_v), .req_ready_o(ntk_rdy), .req_i(ntk_req),
      .in_a_i, .in_b_i,
      .notify_pending_i(ntk_pend), .notify_clear_o(ntk_clr),
      .cpl_valid_o(ntk_cpl), .cpl_ready_i(ntk_ack), .cpl_o(ntk_c), .ntk_o(ntk_rec),
      .irq_o(ntk_irq), .isr_o(ntk_isr), .ack_valid_i, .ack_i,
      .rd_valid_o, .rd_ready_i, .rd_addr_o, .rd_len_o,
      .rd_rsp_valid_i, .rd_rsp_ready_o,
      .rd_rsp_ok_i, .rd_rsp_addr_i, .rd_rsp_len_i, .rd_rsp_data_i,
      .wr_valid_o, .wr_ready_i, .wr_addr_o, .wr_len_o, .wr_data_o,
      .wr_rsp_valid_i, .wr_rsp_ready_o, .wr_rsp_ok_i
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cpl_q <= '0;
        rec_q <= '0;
        req_q <= '0;
        snap_q <= '0;
        armed_q <= 1'b0;
        clr_q <= '0;
      end else unique case (state_q)
        Idle: if (req_valid_i && req_ready_o) begin
          rec_q <= '0;
          req_q <= req_i;
          state_q <= FireReq;
        end else if (ntk_rdy && notify_pending_i[0] && !vq_ok) begin
          rec_q <= '{
            valid: 1'b0, bound: armed_q, capset: 1'b0, info: 1'b0,
            dispatch: 1'b0, irq: 1'b0, clear: 2'b01, count: 8'd0,
            cfg_rdata: 32'd0, num_capsets: 32'd0, capset_id: 32'd0,
            max_version: 32'd0, max_size: 32'd0, type_word: 32'd0,
            cmd: 32'd0, result: 32'd0, handle: 32'd0, resp_word0: 32'd0,
            used_idx: 16'd0, resp_addr: 64'd0
          };
          cpl_q <= '{status: APU_VQT_FAULT};
          clr_q <= 2'b01;
          state_q <= Clr;
        end else if (ntk_rdy && notify_pending_i[0] && need_arm) begin
          rec_q <= '0;
          state_q <= FireArm;
        end else if (ntk_rdy && notify_pending_i[0]) begin
          rec_q <= '0;
          state_q <= WaitNtk;
        end else if (ntk_rdy && notify_pending_i[1]) begin
          rec_q <= '{
            valid: 1'b0, bound: armed_q, capset: 1'b0, info: 1'b0,
            dispatch: 1'b0, irq: 1'b0, clear: 2'b10, count: 8'd0,
            cfg_rdata: 32'd0, num_capsets: 32'd0, capset_id: 32'd0,
            max_version: 32'd0, max_size: 32'd0, type_word: 32'd0,
            cmd: 32'd0, result: 32'd0, handle: 32'd0, resp_word0: 32'd0,
            used_idx: 16'd0, resp_addr: 64'd0
          };
          cpl_q <= '{status: APU_VQT_FAULT};
          clr_q <= 2'b10;
          state_q <= Clr;
        end
        FireArm: if (ntk_rdy) state_q <= WaitArm;
        WaitArm: if (ntk_cpl) begin
          if (ntk_c.status != APU_NTK_OK) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_VQT_FAULT};
            clr_q <= 2'b01;
            state_q <= Clr;
          end else begin
            armed_q <= 1'b1;
            snap_q <= vq0_i;
            state_q <= WaitNtk;
          end
        end
        FireReq: if (ntk_rdy) state_q <= WaitNtk;
        WaitNtk: if (ntk_cpl) begin
          rec_q <= '{
            valid:       ntk_rec.valid,
            bound:       ntk_rec.bound,
            capset:      ntk_rec.capset,
            info:        ntk_rec.info,
            dispatch:    ntk_rec.dispatch,
            irq:         ntk_rec.irq,
            clear:       ntk_rec.clear,
            count:       ntk_rec.count,
            cfg_rdata:   ntk_rec.cfg_rdata,
            num_capsets: ntk_rec.num_capsets,
            capset_id:   ntk_rec.capset_id,
            max_version: ntk_rec.max_version,
            max_size:    ntk_rec.max_size,
            type_word:   ntk_rec.type_word,
            cmd:         ntk_rec.cmd,
            result:      ntk_rec.result,
            handle:      ntk_rec.handle,
            resp_word0:  ntk_rec.resp_word0,
            used_idx:    ntk_rec.used_idx,
            resp_addr:   ntk_rec.resp_addr
          };
          cpl_q <= '{status: apu_vqt_status_e'(ntk_c.status)};
          state_q <= Done;
        end
        Clr: state_q <= Done;
        Done: if (cpl_ready_i) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    `endif
  end
endmodule

// VqTake (vqt) enable-0 fixture: vq_state[0] arms NotifyTake.
module g6lc_apu_vqt_fixture
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vqt_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  apu_vq_state_t vq0_i,
  input  apu_vq_state_t vq1_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vqt_cpl_t cpl_o,
  output apu_vqt_t vqt_o,
  output logic irq_o,
  output logic [31:0] isr_o,
  input  logic ack_valid_i,
  input  logic [31:0] ack_i,
  output logic rd_valid_o,
  input  logic rd_ready_i,
  output logic [63:0] rd_addr_o,
  output logic [31:0] rd_len_o,
  input  logic rd_rsp_valid_i,
  output logic rd_rsp_ready_o,
  input  logic rd_rsp_ok_i,
  input  logic [63:0] rd_rsp_addr_i,
  input  logic [31:0] rd_rsp_len_i,
  input  logic [APU_VGPU_BEAT_BYTES*8-1:0] rd_rsp_data_i,
  output logic wr_valid_o,
  input  logic wr_ready_i,
  output logic [63:0] wr_addr_o,
  output logic [31:0] wr_len_o,
  output logic [APU_VGPU_BEAT_BYTES*8-1:0] wr_data_o,
  input  logic wr_rsp_valid_i,
  output logic wr_rsp_ready_o,
  input  logic wr_rsp_ok_i
);
  g6lc_apu_vqt #(.Enable(Enable)) i_dut (.*);
endmodule
