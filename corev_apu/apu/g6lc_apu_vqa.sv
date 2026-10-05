// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// virtio vq_state[0] supplies desc/avail/used/num and arms
// NotifyTakeAlloc on notify_pending[0]. A doorbell with ready=0
// faults and still clears. Cursor pending[1] is forwarded after
// the queue is armed. CFG still fires through NotifyTakeAlloc.
// Enable=0 elaborates no datapath. Does not edit virtio_mmio,
// g6lc_apu_vgpu_avail, or g6lc_apu_sys. FeatureVirgl stays
// illegal. ApuCfg.NumCapsets stays 0.

// VqTakeAlloc (vqa): virtio vq_state[0] arms NotifyTakeAlloc on notify_pending[0]. Default-off. FeatureVirgl stays illegal.
// Interplay: VqTakeAlloc (vqa) --> NotifyTakeAlloc (nta). --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_vqa
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vqa_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  apu_vq_state_t vq0_i,
  input  apu_vq_state_t vq1_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vqa_cpl_t cpl_o,
  output apu_vqa_t vqa_o,
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
    assign vqa_o = '0;
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
      Idle, FireArm, WaitArm, FireReq, WaitNta, Clr, Done
    } state_e;
    state_e state_q;
    apu_vqa_cpl_t cpl_q;
    apu_vqa_t rec_q;
    apu_vqa_req_t req_q;
    apu_vq_state_t snap_q;
    logic armed_q;
    logic [APU_NUM_QUEUES-1:0] clr_q, nta_pend, nta_clr;
    logic vq_ok, need_arm;
    logic nta_req_v, nta_rdy, nta_cpl, nta_ack, nta_irq;
    logic [31:0] nta_isr;
    apu_nta_req_t nta_req, arm_req;
    apu_nta_cpl_t nta_c;
    apu_nta_t nta_rec;

    assign req_ready_o = state_q == Idle && rst_ni && nta_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vqa_cpl_t'('0);
    assign vqa_o = rec_q;
    assign irq_o = nta_irq;
    assign isr_o = nta_isr;
    assign notify_clear_o = (state_q == Clr) ? clr_q : nta_clr;
    assign nta_req_v = (state_q == FireArm) || (state_q == FireReq);
    assign nta_ack = (state_q == WaitArm) || (state_q == WaitNta);
    assign nta_pend = (state_q == WaitNta) ? notify_pending_i : '0;
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
      arm_req.qpa.vca.op = APU_VCA_NOTIFY;
      arm_req.qpa.vca.qta.qal.avu.avail_base = vq0_i.avail;
      arm_req.qpa.vca.qta.qal.avu.desc_base = vq0_i.desc;
      arm_req.qpa.vca.qta.qal.avu.used_base = vq0_i.used;
      arm_req.qpa.vca.qta.qal.avu.queue_size = vq0_i.num[7:0];
      arm_req.qpa.vca.qta.qal.avu.max_chain = 4'd8;
      nta_req = (state_q == FireArm) ? arm_req : req_q.nta;
    end

    g6lc_apu_nta #(.Enable(1'b1)) i_nta (
      .clk_i, .rst_ni,
      .req_valid_i(nta_req_v), .req_ready_o(nta_rdy), .req_i(nta_req),
      .in_a_i, .in_b_i,
      .notify_pending_i(nta_pend), .notify_clear_o(nta_clr),
      .cpl_valid_o(nta_cpl), .cpl_ready_i(nta_ack), .cpl_o(nta_c), .nta_o(nta_rec),
      .irq_o(nta_irq), .isr_o(nta_isr), .ack_valid_i, .ack_i,
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
        end else if (nta_rdy && notify_pending_i[0] && !vq_ok) begin
          rec_q <= '{
            valid: 1'b0, bound: armed_q, capset: 1'b0, info: 1'b0,
            alloc: 1'b0, dispatch: 1'b0, irq: 1'b0, clear: 2'b01, count: 8'd0,
            cfg_rdata: 32'd0, num_capsets: 32'd0, capset_id: 32'd0,
            max_version: 32'd0, max_size: 32'd0, type_word: 32'd0,
            cmd: 32'd0, result: 32'd0, handle: 32'd0, resp_word0: 32'd0,
            used_idx: 16'd0, resp_addr: 64'd0
          };
          cpl_q <= '{status: APU_VQA_FAULT};
          clr_q <= 2'b01;
          state_q <= Clr;
        end else if (nta_rdy && notify_pending_i[0] && need_arm) begin
          rec_q <= '0;
          state_q <= FireArm;
        end else if (nta_rdy && notify_pending_i[0]) begin
          rec_q <= '0;
          state_q <= WaitNta;
        end else if (nta_rdy && notify_pending_i[1]) begin
          rec_q <= '{
            valid: 1'b0, bound: armed_q, capset: 1'b0, info: 1'b0,
            alloc: 1'b0, dispatch: 1'b0, irq: 1'b0, clear: 2'b10, count: 8'd0,
            cfg_rdata: 32'd0, num_capsets: 32'd0, capset_id: 32'd0,
            max_version: 32'd0, max_size: 32'd0, type_word: 32'd0,
            cmd: 32'd0, result: 32'd0, handle: 32'd0, resp_word0: 32'd0,
            used_idx: 16'd0, resp_addr: 64'd0
          };
          cpl_q <= '{status: APU_VQA_FAULT};
          clr_q <= 2'b10;
          state_q <= Clr;
        end
        FireArm: if (nta_rdy) state_q <= WaitArm;
        WaitArm: if (nta_cpl) begin
          if (nta_c.status != APU_NTA_OK) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_VQA_FAULT};
            clr_q <= 2'b01;
            state_q <= Clr;
          end else begin
            armed_q <= 1'b1;
            snap_q <= vq0_i;
            state_q <= WaitNta;
          end
        end
        FireReq: if (nta_rdy) state_q <= WaitNta;
        WaitNta: if (nta_cpl) begin
          rec_q <= '{
            valid:       nta_rec.valid,
            bound:       nta_rec.bound,
            capset:      nta_rec.capset,
            info:        nta_rec.info,
            alloc:       nta_rec.alloc,
            dispatch:    nta_rec.dispatch,
            irq:         nta_rec.irq,
            clear:       nta_rec.clear,
            count:       nta_rec.count,
            cfg_rdata:   nta_rec.cfg_rdata,
            num_capsets: nta_rec.num_capsets,
            capset_id:   nta_rec.capset_id,
            max_version: nta_rec.max_version,
            max_size:    nta_rec.max_size,
            type_word:   nta_rec.type_word,
            cmd:         nta_rec.cmd,
            result:      nta_rec.result,
            handle:      nta_rec.handle,
            resp_word0:  nta_rec.resp_word0,
            used_idx:    nta_rec.used_idx,
            resp_addr:   nta_rec.resp_addr
          };
          cpl_q <= '{status: apu_vqa_status_e'(nta_c.status)};
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

// VqTakeAlloc (vqa) enable-0 fixture: vq_state[0] arms NotifyTakeAlloc.
module g6lc_apu_vqa_fixture
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vqa_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  apu_vq_state_t vq0_i,
  input  apu_vq_state_t vq1_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vqa_cpl_t cpl_o,
  output apu_vqa_t vqa_o,
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
  g6lc_apu_vqa #(.Enable(Enable)) i_dut (.*);
endmodule
