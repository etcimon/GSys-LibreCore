// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// virtio vq_state[0] supplies desc/avail/used/num and arms
// NotifyTakeBegin on notify_pending[0]. A doorbell with ready=0
// faults and still clears. Cursor pending[1] is forwarded after
// the queue is armed. CFG still fires through NotifyTakeBegin.
// Enable=0 elaborates no datapath. Does not edit virtio_mmio,
// g6lc_apu_vgpu_avail, or g6lc_apu_sys. FeatureVirgl stays
// illegal. ApuCfg.NumCapsets stays 0.

// VqTakeBegin (vqb): virtio vq_state[0] arms NotifyTakeBegin on notify_pending[0]. Default-off. FeatureVirgl stays illegal.
// Interplay: VqTakeBegin (vqb) --> NotifyTakeBegin (ntb). --? VqTakeAlloc (vqa) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_vqb
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vqb_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  apu_vq_state_t vq0_i,
  input  apu_vq_state_t vq1_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vqb_cpl_t cpl_o,
  output apu_vqb_t vqb_o,
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
    assign vqb_o = '0;
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
      Idle, FireArm, WaitArm, FireReq, WaitNtb, Clr, Done
    } state_e;
    state_e state_q;
    apu_vqb_cpl_t cpl_q;
    apu_vqb_t rec_q;
    apu_vqb_req_t req_q;
    apu_vq_state_t snap_q;
    logic armed_q;
    logic [APU_NUM_QUEUES-1:0] clr_q, ntb_pend, ntb_clr;
    logic vq_ok, need_arm;
    logic ntb_req_v, ntb_rdy, ntb_cpl, ntb_ack, ntb_irq;
    logic [31:0] ntb_isr;
    apu_ntb_req_t ntb_req, arm_req;
    apu_ntb_cpl_t ntb_c;
    apu_ntb_t ntb_rec;

    assign req_ready_o = state_q == Idle && rst_ni && ntb_rdy;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_vqb_cpl_t'('0);
    assign vqb_o = rec_q;
    assign irq_o = ntb_irq;
    assign isr_o = ntb_isr;
    assign notify_clear_o = (state_q == Clr) ? clr_q : ntb_clr;
    assign ntb_req_v = (state_q == FireArm) || (state_q == FireReq);
    assign ntb_ack = (state_q == WaitArm) || (state_q == WaitNtb);
    assign ntb_pend = (state_q == WaitNtb) ? notify_pending_i : '0;
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
      arm_req.qpb.vcb.op = APU_VCB_NOTIFY;
      arm_req.qpb.vcb.qtb.qbn.avu.avail_base = vq0_i.avail;
      arm_req.qpb.vcb.qtb.qbn.avu.desc_base = vq0_i.desc;
      arm_req.qpb.vcb.qtb.qbn.avu.used_base = vq0_i.used;
      arm_req.qpb.vcb.qtb.qbn.avu.queue_size = vq0_i.num[7:0];
      arm_req.qpb.vcb.qtb.qbn.avu.max_chain = 4'd8;
      ntb_req = (state_q == FireArm) ? arm_req : req_q.ntb;
    end

    g6lc_apu_ntb #(.Enable(1'b1)) i_ntb (
      .clk_i, .rst_ni,
      .req_valid_i(ntb_req_v), .req_ready_o(ntb_rdy), .req_i(ntb_req),
      .in_a_i, .in_b_i,
      .notify_pending_i(ntb_pend), .notify_clear_o(ntb_clr),
      .cpl_valid_o(ntb_cpl), .cpl_ready_i(ntb_ack), .cpl_o(ntb_c), .ntb_o(ntb_rec),
      .irq_o(ntb_irq), .isr_o(ntb_isr), .ack_valid_i, .ack_i,
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
        end else if (ntb_rdy && notify_pending_i[0] && !vq_ok) begin
          rec_q <= '{
            valid: 1'b0, bound: armed_q, capset: 1'b0, info: 1'b0,
            alloc: 1'b0, begin_cmd: 1'b0, dispatch: 1'b0, irq: 1'b0,
            clear: 2'b01, count: 8'd0, cfg_rdata: 32'd0, num_capsets: 32'd0,
            capset_id: 32'd0, max_version: 32'd0, max_size: 32'd0,
            type_word: 32'd0, cmd: 32'd0, result: 32'd0, handle: 32'd0,
            resp_word0: 32'd0, used_idx: 16'd0, resp_addr: 64'd0
          };
          cpl_q <= '{status: APU_VQB_FAULT};
          clr_q <= 2'b01;
          state_q <= Clr;
        end else if (ntb_rdy && notify_pending_i[0] && need_arm) begin
          rec_q <= '0;
          state_q <= FireArm;
        end else if (ntb_rdy && notify_pending_i[0]) begin
          rec_q <= '0;
          state_q <= WaitNtb;
        end else if (ntb_rdy && notify_pending_i[1]) begin
          rec_q <= '{
            valid: 1'b0, bound: armed_q, capset: 1'b0, info: 1'b0,
            alloc: 1'b0, begin_cmd: 1'b0, dispatch: 1'b0, irq: 1'b0,
            clear: 2'b10, count: 8'd0, cfg_rdata: 32'd0, num_capsets: 32'd0,
            capset_id: 32'd0, max_version: 32'd0, max_size: 32'd0,
            type_word: 32'd0, cmd: 32'd0, result: 32'd0, handle: 32'd0,
            resp_word0: 32'd0, used_idx: 16'd0, resp_addr: 64'd0
          };
          cpl_q <= '{status: APU_VQB_FAULT};
          clr_q <= 2'b10;
          state_q <= Clr;
        end
        FireArm: if (ntb_rdy) state_q <= WaitArm;
        WaitArm: if (ntb_cpl) begin
          if (ntb_c.status != APU_NTB_OK) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_VQB_FAULT};
            clr_q <= 2'b01;
            state_q <= Clr;
          end else begin
            armed_q <= 1'b1;
            snap_q <= vq0_i;
            state_q <= WaitNtb;
          end
        end
        FireReq: if (ntb_rdy) state_q <= WaitNtb;
        WaitNtb: if (ntb_cpl) begin
          rec_q <= '{
            valid:       ntb_rec.valid,
            bound:       ntb_rec.bound,
            capset:      ntb_rec.capset,
            info:        ntb_rec.info,
            alloc:       ntb_rec.alloc,
            begin_cmd:   ntb_rec.begin_cmd,
            dispatch:    ntb_rec.dispatch,
            irq:         ntb_rec.irq,
            clear:       ntb_rec.clear,
            count:       ntb_rec.count,
            cfg_rdata:   ntb_rec.cfg_rdata,
            num_capsets: ntb_rec.num_capsets,
            capset_id:   ntb_rec.capset_id,
            max_version: ntb_rec.max_version,
            max_size:    ntb_rec.max_size,
            type_word:   ntb_rec.type_word,
            cmd:         ntb_rec.cmd,
            result:      ntb_rec.result,
            handle:      ntb_rec.handle,
            resp_word0:  ntb_rec.resp_word0,
            used_idx:    ntb_rec.used_idx,
            resp_addr:   ntb_rec.resp_addr
          };
          cpl_q <= '{status: apu_vqb_status_e'(ntb_c.status)};
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

// VqTakeBegin (vqb) enable-0 fixture: vq_state[0] arms NotifyTakeBegin.
module g6lc_apu_vqb_fixture
  import g6lc_apu_pkg::*;
  import g6lc_apu_cfg_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_vqb_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  input  apu_vq_state_t vq0_i,
  input  apu_vq_state_t vq1_i,
  input  logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_vqb_cpl_t cpl_o,
  output apu_vqb_t vqb_o,
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
  g6lc_apu_vqb #(.Enable(Enable)) i_dut (.*);
endmodule
