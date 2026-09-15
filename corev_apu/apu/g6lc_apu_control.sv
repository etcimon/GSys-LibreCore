// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module g6lc_apu_control
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(
  parameter type reg_req_t = apu_reg_req_t,
  parameter type reg_rsp_t = apu_reg_rsp_t
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input reg_req_t req_i,
  output reg_rsp_t rsp_o,
  input logic [31:0] epoch_i,
  input logic [31:0] device_status_i,
  input apu_vq_state_t vq_state_i [APU_NUM_QUEUES],
  input logic [APU_NUM_QUEUES-1:0] queue_enable_i,
  input logic [APU_NUM_QUEUES-1:0] notify_pending_i,
  output logic [APU_NUM_QUEUES-1:0] notify_clear_o,
  input logic reset_req_i,
  output logic reset_ack_o,
  input logic [APU_NUM_QUEUES-1:0] queue_stop_req_i,
  output logic [APU_NUM_QUEUES-1:0] queue_stop_ack_o,
  input logic backend_reset_done_i,
  input logic [APU_NUM_QUEUES-1:0] backend_idle_i,
  input logic [31:0] last_used_qid_i,
  input logic [31:0] last_used_context_i,
  input logic [63:0] last_used_fence_i,
  input logic [31:0] last_used_len_i,
  output logic irq_o
);
  localparam int QidWidth = $clog2(APU_NUM_QUEUES);
  logic [31:0] queue_sel_q, epoch_q, snap_epoch_q;
  apu_vq_state_t snap_vq_q;
  logic [31:0] snap_cpl_qid_q, snap_context_q, snap_len_q;
  logic [63:0] snap_fence_q;
  logic [QidWidth-1:0] snap_qid_q;
  logic snap_valid_q, snap_valid, reset_seen_q;
  logic [APU_NUM_QUEUES-1:0] stop_seen_q;
  logic qsel_valid, write_fire;
  logic [QidWidth-1:0] qsel_idx;

  assign qsel_valid = queue_sel_q < APU_NUM_QUEUES;
  assign qsel_idx = qsel_valid ? queue_sel_q[QidWidth-1:0] : '0;
  assign snap_valid = snap_valid_q && snap_epoch_q == epoch_i &&
                      queue_enable_i[snap_qid_q] && !reset_req_i;
  assign write_fire = req_i.valid && req_i.write && !rsp_o.error;
  assign reset_ack_o = reset_req_i && reset_seen_q && epoch_q == epoch_i &&
                       backend_reset_done_i && (&backend_idle_i);
  assign queue_stop_ack_o = queue_stop_req_i & stop_seen_q & backend_idle_i &
                            {APU_NUM_QUEUES{epoch_q == epoch_i}};
  assign notify_clear_o = write_fire && req_i.addr == 64'(ACTRL_NOTIFY_CLEAR) ?
                          req_i.wdata[APU_NUM_QUEUES-1:0] : '0;
  assign irq_o = reset_req_i || (|queue_stop_req_i) || (|notify_pending_i);

  always_comb begin
    rsp_o = '0;
    rsp_o.ready = req_i.valid;
    if (req_i.valid) begin
      rsp_o.error = req_i.addr[1:0] != 0 || (req_i.write && req_i.wstrb != 4'hf);
      if (req_i.write) begin
        unique case (req_i.addr)
          64'(ACTRL_QUEUE_SEL):
            rsp_o.error |= req_i.wdata >= APU_NUM_QUEUES;
          64'(ACTRL_SNAPSHOT):
            rsp_o.error |= req_i.wdata != 1 || !qsel_valid ||
                           !queue_enable_i[qsel_idx] || reset_req_i;
          64'(ACTRL_NOTIFY_CLEAR):
            rsp_o.error |= (req_i.wdata & ~32'(queue_enable_i)) != 0 || reset_req_i;
          64'(ACTRL_RESET_ACK):
            rsp_o.error |= req_i.wdata != 1 || !reset_req_i;
          64'(ACTRL_QUEUE_STOP_ACK):
            rsp_o.error |= (req_i.wdata & ~32'(queue_stop_req_i)) != 0;
          default: rsp_o.error = 1'b1;
        endcase
      end else begin
        unique case (req_i.addr)
          64'(ACTRL_MAGIC): rsp_o.rdata = APU_CONTROL_MAGIC;
          64'(ACTRL_VERSION): rsp_o.rdata = 32'd1;
          64'(ACTRL_STATUS): rsp_o.rdata = {22'h0, snap_valid, backend_idle_i,
              queue_enable_i, notify_pending_i, queue_stop_req_i, reset_req_i};
          64'(ACTRL_EPOCH): rsp_o.rdata = epoch_i;
          64'(ACTRL_QUEUE_SEL): rsp_o.rdata = queue_sel_q;
          64'(ACTRL_SNAPSHOT): rsp_o.rdata = {31'h0, snap_valid};
          64'(ACTRL_DEVICE_STATUS): rsp_o.rdata = device_status_i;
          64'(ACTRL_SNAP_EPOCH): rsp_o.rdata = snap_epoch_q;
          64'(ACTRL_SNAP_NUM): rsp_o.rdata = {16'h0, snap_vq_q.num};
          64'(ACTRL_SNAP_DESC_LO): rsp_o.rdata = snap_vq_q.desc[31:0];
          64'(ACTRL_SNAP_DESC_HI): rsp_o.rdata = snap_vq_q.desc[63:32];
          64'(ACTRL_SNAP_AVAIL_LO): rsp_o.rdata = snap_vq_q.avail[31:0];
          64'(ACTRL_SNAP_AVAIL_HI): rsp_o.rdata = snap_vq_q.avail[63:32];
          64'(ACTRL_SNAP_USED_LO): rsp_o.rdata = snap_vq_q.used[31:0];
          64'(ACTRL_SNAP_USED_HI): rsp_o.rdata = snap_vq_q.used[63:32];
          64'(ACTRL_SNAP_CPL_QID): rsp_o.rdata = snap_cpl_qid_q;
          64'(ACTRL_SNAP_CPL_CONTEXT): rsp_o.rdata = snap_context_q;
          64'(ACTRL_SNAP_CPL_FENCE_LO): rsp_o.rdata = snap_fence_q[31:0];
          64'(ACTRL_SNAP_CPL_FENCE_HI): rsp_o.rdata = snap_fence_q[63:32];
          64'(ACTRL_SNAP_CPL_LEN): rsp_o.rdata = snap_len_q;
          default: rsp_o.error = 1'b1;
        endcase
        if (req_i.addr >= 64'(ACTRL_SNAP_EPOCH)) rsp_o.error |= !snap_valid;
      end
      if (rsp_o.error) rsp_o.rdata = '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      queue_sel_q <= '0;
      epoch_q <= '0;
      snap_epoch_q <= '0;
      snap_vq_q <= '0;
      snap_cpl_qid_q <= '0;
      snap_context_q <= '0;
      snap_fence_q <= '0;
      snap_len_q <= '0;
      snap_qid_q <= '0;
      snap_valid_q <= 1'b0;
      reset_seen_q <= 1'b0;
      stop_seen_q <= '0;
    end else begin
      epoch_q <= epoch_i;
      if (!reset_req_i || epoch_q != epoch_i) reset_seen_q <= 1'b0;
      stop_seen_q <= stop_seen_q & queue_stop_req_i & {APU_NUM_QUEUES{epoch_q == epoch_i}};
      if (!snap_valid) snap_valid_q <= 1'b0;
      if (write_fire) begin
        unique case (req_i.addr)
          64'(ACTRL_QUEUE_SEL): begin
            queue_sel_q <= req_i.wdata;
            snap_valid_q <= 1'b0;
          end
          64'(ACTRL_SNAPSHOT): begin
            snap_vq_q <= vq_state_i[qsel_idx];
            snap_qid_q <= qsel_idx;
            snap_epoch_q <= epoch_i;
            snap_cpl_qid_q <= last_used_qid_i;
            snap_context_q <= last_used_context_i;
            snap_fence_q <= last_used_fence_i;
            snap_len_q <= last_used_len_i;
            snap_valid_q <= 1'b1;
          end
          64'(ACTRL_RESET_ACK): reset_seen_q <= 1'b1;
          64'(ACTRL_QUEUE_STOP_ACK): stop_seen_q <=
              (stop_seen_q & queue_stop_req_i & {APU_NUM_QUEUES{epoch_q == epoch_i}}) |
              req_i.wdata[APU_NUM_QUEUES-1:0];
          default: ;
        endcase
      end
    end
  end

  logic unused_testmode;
  assign unused_testmode = testmode_i;
endmodule
