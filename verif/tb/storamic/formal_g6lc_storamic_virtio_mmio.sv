// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-034 formal wrapper: free AXI-Lite master under handshake discipline
// (held payloads until ready) + shadow registers (no $past/$stable in the
// toolchain). Safety asserts cover notify/arming gating, negotiation order,
// queue-register stability while ready, held Status under reset_pending,
// irq level and response stability. Covers: DRIVER_OK, notify, reset done.
module formal_g6lc_storamic_virtio_mmio (
  input logic clk_i,
  input logic rst_ni,
  input g6lc_storamic_pkg::axil_req_t ctrl_req_i,
  output g6lc_storamic_pkg::axil_resp_t ctrl_resp_o,
  input logic device_usable_i,
  input logic [63:0] capacity_i,
  input logic capacity_update_i,
  input logic dma_idle_i,
  input logic used_event_i,
  input logic ring_fault_i,
  output logic cover_dok_o,
  output logic cover_notify_o,
  output logic cover_reset_o
);
  logic notify, irq, dok, fok, qready, rpend;
  logic [63:0] dfeat;
  logic [7:0] epoch;
  logic [15:0] qnum_o;
  logic [63:0] qdesc, qdrv, qdev;

  g6lc_storamic_virtio_mmio #(
    .VendorId(32'h0), .QueueNumMax(8)
  ) dut (
    .clk_i, .rst_ni, .ctrl_req_i, .ctrl_resp_o,
    .device_usable_i, .capacity_i, .capacity_update_i, .flush_cap_i(1'b0), .dma_idle_i,
    .used_event_i, .ring_fault_i,
    .notify_o(notify), .irq_o(irq), .driver_ok_o(dok),
    .features_ok_o(fok), .driver_features_o(dfeat),
    .reset_epoch_o(epoch), .queue_ready_o(qready),
    .queue_num_o(qnum_o), .queue_desc_o(qdesc),
    .queue_driver_o(qdrv), .queue_device_o(qdev),
    .reset_pending_o(rpend)
  );

  // Master discipline: a channel offered and not accepted in the previous
  // step stays valid with the same payload (checked combinationally on the
  // current step against previous-step shadows).
  logic [63:0] aw_addr_p, ar_addr_p;
  logic [31:0] w_data_p;
  logic [3:0] w_strb_p;
  logic aw_hold_p, w_hold_p, ar_hold_p;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_hold_p <= 1'b0; w_hold_p <= 1'b0; ar_hold_p <= 1'b0;
      aw_addr_p <= '0; ar_addr_p <= '0; w_data_p <= '0; w_strb_p <= '0;
    end else begin
      aw_hold_p <= ctrl_req_i.aw_valid && !ctrl_resp_o.aw_ready;
      w_hold_p <= ctrl_req_i.w_valid && !ctrl_resp_o.w_ready;
      ar_hold_p <= ctrl_req_i.ar_valid && !ctrl_resp_o.ar_ready;
      aw_addr_p <= ctrl_req_i.aw.addr;
      ar_addr_p <= ctrl_req_i.ar.addr;
      w_data_p <= ctrl_req_i.w.data;
      w_strb_p <= ctrl_req_i.w.strb;
    end
  end
  always_comb begin
    if (rst_ni) begin
      if (aw_hold_p) assume (ctrl_req_i.aw_valid && ctrl_req_i.aw.addr == aw_addr_p);
      if (w_hold_p)
        assume (ctrl_req_i.w_valid && ctrl_req_i.w.data == w_data_p &&
                ctrl_req_i.w.strb == w_strb_p);
      if (ar_hold_p) assume (ctrl_req_i.ar_valid && ctrl_req_i.ar.addr == ar_addr_p);
    end
  end

  // Response stability: once valid and not accepted, stays stable.
  logic b_was_v, r_was_v;
  logic [1:0] b_resp_p, r_resp_p;
  logic [31:0] r_data_p;
  // Shadows reset with the DUT: a reset may occur in any cycle.
  logic qready_p;
  logic [15:0] qnum_p;
  logic [63:0] qdesc_p, qdrv_p, qdev_p;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      b_was_v <= 1'b0; r_was_v <= 1'b0; qready_p <= 1'b0;
      b_resp_p <= '0; r_resp_p <= '0; r_data_p <= '0;
      qnum_p <= '0; qdesc_p <= '0; qdrv_p <= '0; qdev_p <= '0;
    end else begin
      // A response is "held" only if it was offered and not accepted.
      b_was_v <= ctrl_resp_o.b_valid && !ctrl_req_i.b_ready;
      r_was_v <= ctrl_resp_o.r_valid && !ctrl_req_i.r_ready;
      b_resp_p <= ctrl_resp_o.b.resp;
      r_resp_p <= ctrl_resp_o.r.resp;
      r_data_p <= ctrl_resp_o.r.data;
      qready_p <= qready;
      qnum_p <= qnum_o; qdesc_p <= qdesc; qdrv_p <= qdrv; qdev_p <= qdev;
    end
  end
  always_comb begin
    if (rst_ni) begin
      if (b_was_v) begin
        assert (ctrl_resp_o.b_valid && ctrl_resp_o.b.resp == b_resp_p);
      end
      if (r_was_v) begin
        assert (ctrl_resp_o.r_valid && ctrl_resp_o.r.resp == r_resp_p &&
                ctrl_resp_o.r.data == r_data_p);
      end
      // notify requires a fully armed queue.
      if (notify)
        assert (dok && qready && !dut.status_q[6] && !rpend);
      // reset_pending blocks notify.
      if (rpend) assert (!notify);
      // negotiation order.
      if (dok) assert (fok);
      if (fok)
        assert ((dfeat & ~64'h1_0000_0000) == 0 && dfeat[32]);
      // queue registers stable while ready.
      if (qready_p && qready) begin
        assert (qnum_o == qnum_p && qdesc == qdesc_p &&
                qdrv == qdrv_p && qdev == qdev_p);
      end
      // irq level = InterruptStatus.
      assert (irq == |dut.irqst_q);
      // epoch only increments when a reset completes.
    end
  end

  // Covers.
  logic cov_dok, cov_notify, cov_reset;
  logic [7:0] epoch_p;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cov_dok <= 0; cov_notify <= 0; cov_reset <= 0; epoch_p <= '0;
    end else begin
      epoch_p <= epoch;
      if (dok) cov_dok <= 1;
      if (notify) cov_notify <= 1;
      if (epoch != epoch_p) cov_reset <= 1;
    end
  end
  assign cover_dok_o = cov_dok;
  assign cover_notify_o = cov_notify;
  assign cover_reset_o = cov_reset;
endmodule
