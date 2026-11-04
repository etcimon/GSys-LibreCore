// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-034 standalone VirtIO 1.4 MMIO register/state block (one device, one
// queue, ST-033A profile). AXI-Lite ctrl seam identical in shape to
// g6lc_storamic_regs: AW and W latch independently, one read and one write
// outstanding, held B/R responses, async active-low reset. The transport
// exposes VERSION_1 only, one 128-deep queue, a 96-byte block config window
// (capacity snapshot + ConfigGeneration), a Level IRQ from InterruptStatus,
// and a Status=0/reset that waits for dma_idle_i before clearing. QueueReady
// runs the alignment/extent legality checks; QueueNotify pulses notify_o
// only for a fully-armed queue under DRIVER_OK. DEVICE_NEEDS_RESET is
// device-set only and blocks notify.
module g6lc_storamic_virtio_mmio #(
  parameter logic [31:0] VendorId = 32'h0,
  parameter int unsigned QueueNumMax = 128
) (
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
  output logic notify_o,
  output logic irq_o,
  output logic driver_ok_o,
  output logic features_ok_o,
  output logic [63:0] driver_features_o,
  output logic [7:0] reset_epoch_o,
  output logic queue_ready_o,
  output logic [15:0] queue_num_o,
  output logic [63:0] queue_desc_o,
  output logic [63:0] queue_driver_o,
  output logic [63:0] queue_device_o,
  output logic reset_pending_o
);

  if (!(QueueNumMax >= 1 && QueueNumMax <= 128 &&
        (QueueNumMax & (QueueNumMax - 1)) == 0)) begin : gen_qmax_guard
    // pragma translate_off
    initial $fatal(1, "STORAMIC_VIRTIO_QUEUEMAX");
    // pragma translate_on
  end

  // ---- AXI-Lite channel state (AW and W latch independently) ----
  logic [11:0] aw_addr_q;
  logic aw_v_q, w_v_q, b_v_q, r_v_q;
  logic [31:0] w_data_q;
  logic [3:0] w_strb_q;
  logic [1:0] b_resp_q, r_resp_q;
  logic [31:0] r_data_q;
  logic [11:0] ar_addr_q;

  // ---- architectural state ----
  logic [7:0] status_q;        // {FAILED[7], NEEDS_RESET[6], FOK[3], DOK[2]}
  logic reset_pend_q;
  logic [31:0] drv_feat0_q, drv_feat1_q;
  logic [31:0] feat_sel_q, drv_sel_q, qsel_q;
  logic [15:0] qnum_q;
  logic [63:0] qdesc_q, qdrv_q, qdev_q;
  logic qready_q;
  logic [1:0] irqst_q;
  logic [7:0] epoch_q, cfggen_q;
  logic [63:0] cap_q;

  localparam logic [7:0] StatusWritable = 8'h8F; // {128,8,4,2,1}

  logic notify_q;
  // A ring fault registered on the same edge as an accepted QueueNotify
  // suppresses the pulse: DEVICE_NEEDS_RESET always blocks new work.
  assign notify_o = notify_q && !status_q[6];
  assign driver_ok_o = status_q[2];
  assign features_ok_o = status_q[3];
  assign driver_features_o = {drv_feat1_q, drv_feat0_q};
  assign reset_epoch_o = epoch_q;
  assign queue_ready_o = qready_q;
  assign queue_num_o = qnum_q;
  assign queue_desc_o = qdesc_q;
  assign queue_driver_o = qdrv_q;
  assign queue_device_o = qdev_q;
  assign reset_pending_o = reset_pend_q;
  assign irq_o = |irqst_q;

  // ---- read decode (incoming AR address, mirroring regs) ----
  logic [31:0] rd_data;
  logic rd_err;
  always_comb begin
    rd_data = '0; rd_err = 0;
    if (ctrl_req_i.ar.addr[11:0] < 12'h100) begin
      if (ctrl_req_i.ar.addr[1:0] != 0) rd_err = 1;
      else case (ctrl_req_i.ar.addr[11:0])
        12'h000: rd_data = 32'h7472_6976;
        12'h004: rd_data = 32'd2;
        12'h008: rd_data = {31'h0, device_usable_i, 1'b0};
        12'h00C: rd_data = VendorId;
        12'h010: rd_data = (feat_sel_q == 32'd1) ? 32'h1 : 32'h0;
        12'h034: rd_data = (qsel_q == 32'd0) ? 32'(QueueNumMax) : 32'h0;
        12'h044: rd_data = {31'h0, (qsel_q == 32'd0) && qready_q};
        12'h060: rd_data = {30'h0, irqst_q};
        12'h070: rd_data = {24'h0, status_q};
        12'h0B0, 12'h0B4: rd_data = 32'hFFFF_FFFF;
        12'h0B8, 12'h0BC: rd_data = 32'h0;
        12'h0C0: rd_data = 32'h0;
        12'h0FC: rd_data = {24'h0, cfggen_q};
        default: rd_err = 1;
      endcase
    end else if (ctrl_req_i.ar.addr[11:0] < 12'h160) begin
      // 96-byte block config: byte-readable, aligned word returned.
      unique case (ctrl_req_i.ar.addr[7:2])
        6'h00: rd_data = cap_q[31:0];
        6'h01: rd_data = cap_q[63:32];
        default: rd_data = 32'h0;
      endcase
    end else rd_err = 1;
  end

  // ---- write decode ----
  logic [31:0] wr_data;
  logic [3:0] wr_strb;
  logic wr_err;
  // AW and W arrive independently; the write executes when both are held.
  assign wr_data = w_v_q ? w_data_q : ctrl_req_i.w.data;
  assign wr_strb = w_v_q ? w_strb_q : ctrl_req_i.w.strb;
  logic wr_go;
  assign wr_go = (aw_v_q || ctrl_req_i.aw_valid) &&
                 (w_v_q || ctrl_req_i.w_valid);
  logic [11:0] aw_a;
  assign aw_a = aw_v_q ? aw_addr_q : ctrl_req_i.aw.addr[11:0];

  always_comb begin
    wr_err = 0;
    if (aw_a < 12'h100) begin
      if (aw_a[1:0] != 0 || wr_strb != 4'hF) wr_err = 1;
      else case (aw_a)
        12'h014, 12'h020, 12'h024, 12'h030, 12'h038, 12'h044, 12'h050,
        12'h064, 12'h070, 12'h080, 12'h084, 12'h090, 12'h094, 12'h0A0,
        12'h0A4, 12'h0AC, 12'h0C0: ;
        default: wr_err = 1;
      endcase
    end else if (aw_a < 12'h160) ; // config writes accepted, ignored
    else wr_err = 1;
  end

  // ---- sequential ----
  logic [7:0] nstatus;
  logic fok_ok, dok_ok, qnum_ok, align_ok, extent_ok;
  logic [64:0] d_end, a_end, u_end;
  assign nstatus = wr_data[7:0] & StatusWritable;
  assign fok_ok = (({drv_feat1_q, drv_feat0_q} & ~64'h1_0000_0000) == 0) &&
                  drv_feat1_q[0];
  assign dok_ok = status_q[3];
  assign qnum_ok = qnum_q >= 1 && qnum_q <= 16'(QueueNumMax) &&
                   (qnum_q & (qnum_q - 1)) == 0;
  assign align_ok = qdesc_q[3:0] == 0 && qdrv_q[0] == 0 && qdev_q[1:0] == 0;
  assign d_end = {1'b0, qdesc_q} + 65'(qnum_q) * 65'd16;
  assign a_end = {1'b0, qdrv_q} + 65'd6 + 65'(qnum_q) * 65'd2;
  assign u_end = {1'b0, qdev_q} + 65'd6 + 65'(qnum_q) * 65'd8;
  assign extent_ok = d_end <= 65'h1_0000_0000_0000_0000 &&
                     a_end <= 65'h1_0000_0000_0000_0000 &&
                     u_end <= 65'h1_0000_0000_0000_0000;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_addr_q <= '0; aw_v_q <= 0; w_v_q <= 0;
      b_v_q <= 0; r_v_q <= 0; w_data_q <= '0; w_strb_q <= '0;
      b_resp_q <= '0; r_resp_q <= '0; r_data_q <= '0; ar_addr_q <= '0;
      status_q <= '0; reset_pend_q <= 0;
      drv_feat0_q <= '0; drv_feat1_q <= '0;
      feat_sel_q <= '0; drv_sel_q <= '0; qsel_q <= '0;
      qnum_q <= '0; qdesc_q <= '0; qdrv_q <= '0; qdev_q <= '0;
      qready_q <= 0; irqst_q <= '0; epoch_q <= '0; cfggen_q <= '0;
      cap_q <= '0; notify_q <= 0;
    end else begin
      notify_q <= 1'b0;
      // Events (win over ACK below).
      if (used_event_i) irqst_q[0] <= 1'b1;
      if (ring_fault_i) begin
        irqst_q[1] <= 1'b1; status_q[6] <= 1'b1;
      end
      if (capacity_update_i) begin
        irqst_q[1] <= 1'b1;
        cap_q <= capacity_i;
        cfggen_q <= cfggen_q + 1;
      end else if (status_q == 8'h0 && !reset_pend_q) begin
        // Before the driver starts (Status 0) the snapshot simply follows the
        // media-side capacity: there is no driver to notify yet.
        cap_q <= capacity_i;
      end
      // Reset completion.
      if (reset_pend_q && dma_idle_i) begin
        status_q <= '0; reset_pend_q <= 0;
        drv_feat0_q <= '0; drv_feat1_q <= '0;
        feat_sel_q <= '0; drv_sel_q <= '0; qsel_q <= '0;
        qnum_q <= '0; qdesc_q <= '0; qdrv_q <= '0; qdev_q <= '0;
        qready_q <= 0; irqst_q <= '0; epoch_q <= epoch_q + 1;
      end
      // Channel accepts.
      if (ctrl_req_i.aw_valid && !aw_v_q && !b_v_q) begin
        aw_v_q <= 1'b1; aw_addr_q <= ctrl_req_i.aw.addr[11:0];
      end
      if (ctrl_req_i.w_valid && !w_v_q && !b_v_q) begin
        w_v_q <= 1'b1;
        w_data_q <= ctrl_req_i.w.data; w_strb_q <= ctrl_req_i.w.strb;
      end
      if (wr_go && !b_v_q) begin
        aw_v_q <= 0; w_v_q <= 0;
        b_v_q <= 1'b1; b_resp_q <= wr_err ? 2'b10 : 2'b00;
        if (!wr_err && !reset_pend_q) begin
          case (aw_a)
            12'h014: feat_sel_q <= wr_data;
            12'h020: if (!status_q[3]) begin
                if (drv_sel_q == 0) drv_feat0_q <= wr_data;
                else if (drv_sel_q == 1) drv_feat1_q <= wr_data;
              end
            12'h024: drv_sel_q <= wr_data;
            12'h030: qsel_q <= wr_data;
            12'h038: if (qsel_q == 0 && !qready_q) qnum_q <= wr_data[15:0];
            12'h044: if (qsel_q == 0 && wr_data[0] && !qready_q &&
                         status_q[3] && !status_q[2] && qnum_ok &&
                         align_ok && extent_ok) qready_q <= 1'b1;
            12'h050: if (wr_data == 0 && status_q[2] && qready_q &&
                         !status_q[6]) notify_q <= 1'b1;
            12'h064: irqst_q <= (irqst_q & ~wr_data[1:0]) |
                              {capacity_update_i | ring_fault_i,
                               used_event_i};
            12'h070: begin
              if (wr_data == 0) reset_pend_q <= 1'b1;
              else begin
                status_q[0] <= status_q[0] | nstatus[0];
                status_q[1] <= status_q[1] | nstatus[1];
                if (nstatus[3] && fok_ok) status_q[3] <= 1'b1;
                if (nstatus[2] && dok_ok) status_q[2] <= 1'b1;
                status_q[7] <= status_q[7] | nstatus[7];
              end
            end
            12'h080: if (qsel_q == 0 && !qready_q) qdesc_q[31:0] <= wr_data;
            12'h084: if (qsel_q == 0 && !qready_q) qdesc_q[63:32] <= wr_data;
            12'h090: if (qsel_q == 0 && !qready_q) qdrv_q[31:0] <= wr_data;
            12'h094: if (qsel_q == 0 && !qready_q) qdrv_q[63:32] <= wr_data;
            12'h0A0: if (qsel_q == 0 && !qready_q) qdev_q[31:0] <= wr_data;
            12'h0A4: if (qsel_q == 0 && !qready_q) qdev_q[63:32] <= wr_data;
            default: ;
          endcase
        end
      end
      if (b_v_q && ctrl_req_i.b_ready) b_v_q <= 1'b0;
      if (ctrl_req_i.ar_valid && !r_v_q) begin
        r_v_q <= 1'b1; ar_addr_q <= ctrl_req_i.ar.addr[11:0];
        r_data_q <= rd_data; r_resp_q <= rd_err ? 2'b10 : 2'b00;
      end
      if (r_v_q && ctrl_req_i.r_ready) r_v_q <= 1'b0;
    end
  end

  assign ctrl_resp_o.aw_ready = !aw_v_q && !b_v_q;
  assign ctrl_resp_o.w_ready = !w_v_q && !b_v_q;
  assign ctrl_resp_o.b_valid = b_v_q;
  assign ctrl_resp_o.b.resp = b_resp_q;
  assign ctrl_resp_o.ar_ready = !r_v_q;
  assign ctrl_resp_o.r_valid = r_v_q;
  assign ctrl_resp_o.r.data = r_data_q;
  assign ctrl_resp_o.r.resp = r_resp_q;

  // Simulation-only register trace, enabled by +g6lc_virtio_mmio_trace.
  // pragma translate_off
`ifndef SYNTHESIS
  bit trace_en;
  initial trace_en = $test$plusargs("g6lc_virtio_mmio_trace");
  always @(posedge clk_i) begin
    if (trace_en && rst_ni) begin
      if (wr_go && !b_v_q)
        $display("[virtio-mmio] t=%0t W a=%03h d=%08h strb=%h err=%0d rpend=%0d status=%02h",
                 $time, aw_a, wr_data, wr_strb, wr_err, reset_pend_q, status_q);
      if (ctrl_req_i.ar_valid && !r_v_q)
        $display("[virtio-mmio] t=%0t R a=%03h d=%08h err=%0d status=%02h",
                 $time, ctrl_req_i.ar.addr[11:0], rd_data, rd_err, status_q);
      if (reset_pend_q && dma_idle_i)
        $display("[virtio-mmio] t=%0t reset complete", $time);
    end
  end
`endif
  // pragma translate_on
endmodule
