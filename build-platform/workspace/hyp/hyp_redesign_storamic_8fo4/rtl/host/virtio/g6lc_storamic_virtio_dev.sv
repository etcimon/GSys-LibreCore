// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-037A standalone virtio-blk device: the ST-034 transport, the ST-035 ring
// engine and the ST-036 block backend behind one AXI-Lite register window,
// one DMA port, one block-store seam and one level interrupt.
//
// DMA sharing: the ring engine and the backend never need the port at the same
// time (the engine is idle from hand-off until the backend responds), but the
// mux still arbitrates explicitly. The owner of a presented request keeps the
// port until its beat returns; the response is routed to the owner recorded at
// grant. Reset quiescence (dma_idle to the transport) requires both engines to
// be idle with nothing outstanding on the shared port.
module g6lc_storamic_virtio_dev #(
  parameter logic [31:0] VendorId = 32'h0,
  parameter int unsigned QueueNumMax = 128,
  parameter int unsigned MaxSegs = 8
) (
  input logic clk_i,
  input logic rst_ni,
  input logic quiesce_i,
  output logic quiesced_o,
  output logic quiesce_error_o,
  // Independent policy/control seal; DMA pause still permits MMIO service.
  input logic ctrl_quiesce_i,
  output logic ctrl_quiesced_o,
  output logic inflight_o,
  input g6lc_storamic_pkg::axil_req_t ctrl_req_i,
  output g6lc_storamic_pkg::axil_resp_t ctrl_resp_o,
  output logic irq_o,
  // media facts supplied by the integration (never fabricated here)
  input logic device_usable_i,
  input logic [63:0] capacity_i,
  input logic capacity_update_i,
  input logic [159:0] serial_i,
  input logic store_ready_i,
  // DMA window and port
  input logic [63:0] dma_base_i,
  input logic [63:0] dma_size_i,
  output logic dma_req_o,
  input logic dma_gnt_i,
  output logic dma_we_o,
  output logic [63:0] dma_addr_o,
  output logic [63:0] dma_wdata_o,
  output logic [7:0] dma_be_o,
  input logic dma_rvalid_i,
  input logic [63:0] dma_rdata_i,
  input logic dma_err_i,
  // block store
  output logic st_req_o,
  input logic st_gnt_i,
  output logic st_we_o,
  output logic [63:0] st_addr_o,
  output logic [63:0] st_wdata_o,
  output logic [7:0] st_be_o,
  input logic st_rvalid_i,
  input logic [63:0] st_rdata_i,
  input logic st_err_i,
  // ST-037D FLUSH seam: st_durable_i offers VIRTIO_BLK_F_FLUSH; the backend
  // raises st_flush_req_o for a negotiated FLUSH and holds it until ack/err.
  input logic st_durable_i,
  output logic st_flush_req_o,
  input logic st_flush_ack_i,
  input logic st_flush_err_i
);
  localparam int unsigned SegW = $clog2(MaxSegs + 1);

  // transport <-> ring
  logic notify, driver_ok, queue_ready, reset_pending, used_event, ring_fault;
  logic [15:0] queue_num;
  logic [63:0] queue_desc, queue_driver, queue_device;
  logic [7:0] reset_epoch;
  logic features_ok;
  logic [63:0] driver_features;
  logic ring_idle, blk_idle, port_busy;
  logic ring_quiesced, ring_job_idle, blk_job_idle, ctrl_inflight;
  assign quiesced_o = ring_quiesced && blk_job_idle && !port_busy;
  assign ctrl_quiesced_o = rst_ni && ctrl_quiesce_i && !ctrl_inflight;
  assign inflight_o = !ring_job_idle || !blk_job_idle || port_busy || ctrl_inflight;

  g6lc_storamic_virtio_mmio #(.VendorId(VendorId), .QueueNumMax(QueueNumMax)) i_mmio (
    .clk_i, .rst_ni, .ctrl_req_i, .ctrl_resp_o,
    .quiesce_i(ctrl_quiesce_i), .inflight_o(ctrl_inflight),
    .device_usable_i, .capacity_i, .capacity_update_i,
    .flush_cap_i(st_durable_i),
    .dma_idle_i(ring_idle && blk_idle && !port_busy),
    .used_event_i(used_event), .ring_fault_i(ring_fault),
    .notify_o(notify), .irq_o, .driver_ok_o(driver_ok), .features_ok_o(features_ok),
    .driver_features_o(driver_features), .reset_epoch_o(reset_epoch),
    .queue_ready_o(queue_ready), .queue_num_o(queue_num),
    .queue_desc_o(queue_desc), .queue_driver_o(queue_driver),
    .queue_device_o(queue_device), .reset_pending_o(reset_pending)
  );

  // ring <-> backend
  logic rq_valid, rq_ready, rs_valid, rs_fault;
  logic [15:0] rq_head;
  logic [SegW-1:0] rq_nsegs;
  logic [MaxSegs-1:0][63:0] rq_addr;
  logic [MaxSegs-1:0][31:0] rq_len;
  logic [MaxSegs-1:0] rq_wr;
  logic [31:0] rs_len;

  // DMA sub-ports
  logic r_req, r_gnt, r_we, r_rvalid, b_req, b_gnt, b_we, b_rvalid;
  logic [63:0] r_addr, r_wdata, b_addr, b_wdata;
  logic [7:0] r_be, b_be;

  g6lc_storamic_virtio_ring #(.MaxSegs(MaxSegs), .QueueNumMax(QueueNumMax)) i_ring (
    .clk_i, .rst_ni,
    .queue_ready_i(queue_ready), .queue_num_i(queue_num),
    .queue_desc_i(queue_desc), .queue_driver_i(queue_driver),
    .queue_device_i(queue_device), .driver_ok_i(driver_ok), .notify_i(notify),
    .quiesce_i, .quiesced_o(ring_quiesced), .quiesce_error_o,
    .reset_pending_i(reset_pending), .reset_epoch_i(reset_epoch),
    .dma_idle_o(ring_idle), .job_idle_o(ring_job_idle),
    .used_event_o(used_event), .ring_fault_o(ring_fault),
    .dma_base_i, .dma_size_i,
    .dma_req_o(r_req), .dma_gnt_i(r_gnt), .dma_we_o(r_we), .dma_addr_o(r_addr),
    .dma_wdata_o(r_wdata), .dma_be_o(r_be), .dma_rvalid_i(r_rvalid),
    .dma_rdata_i, .dma_err_i,
    .req_valid_o(rq_valid), .req_ready_i(rq_ready), .req_head_o(rq_head),
    .req_nsegs_o(rq_nsegs), .req_seg_addr_o(rq_addr), .req_seg_len_o(rq_len),
    .req_seg_write_o(rq_wr), .rsp_valid_i(rs_valid),
    .rsp_written_len_i(rs_len), .rsp_fault_i(rs_fault)
  );

  g6lc_storamic_virtio_blk #(.MaxSegs(MaxSegs)) i_blk (
    .clk_i, .rst_ni, .reset_pending_i(reset_pending), .idle_o(blk_idle),
    .job_idle_o(blk_job_idle),
    .req_valid_i(rq_valid), .req_ready_o(rq_ready), .req_nsegs_i(rq_nsegs),
    .req_seg_addr_i(rq_addr), .req_seg_len_i(rq_len), .req_seg_write_i(rq_wr),
    .rsp_valid_o(rs_valid), .rsp_written_len_o(rs_len), .rsp_fault_o(rs_fault),
    .dma_base_i, .dma_size_i,
    .dma_req_o(b_req), .dma_gnt_i(b_gnt), .dma_we_o(b_we), .dma_addr_o(b_addr),
    .dma_wdata_o(b_wdata), .dma_be_o(b_be), .dma_rvalid_i(b_rvalid),
    .dma_rdata_i, .dma_err_i,
    .store_ready_i, .capacity_i, .serial_i,
    .st_req_o, .st_gnt_i, .st_we_o, .st_addr_o, .st_wdata_o, .st_be_o,
    .st_rvalid_i, .st_rdata_i, .st_err_i,
    .flush_en_i(features_ok && driver_features[9] && st_durable_i),
    .st_flush_req_o, .st_flush_ack_i, .st_flush_err_i
  );

  // Shared DMA port: the backend has priority (it only requests while the
  // ring engine waits for it); one beat outstanding, routed by grant owner.
  logic out_q, out_blk_q, sel_blk;
  assign sel_blk = b_req;
  assign port_busy = out_q;
  assign dma_req_o = !out_q && (b_req || r_req);
  assign dma_we_o = sel_blk ? b_we : r_we;
  assign dma_addr_o = sel_blk ? b_addr : r_addr;
  assign dma_wdata_o = sel_blk ? b_wdata : r_wdata;
  assign dma_be_o = sel_blk ? b_be : r_be;
  assign b_gnt = !out_q && b_req && dma_gnt_i;
  assign r_gnt = !out_q && !b_req && r_req && dma_gnt_i;
  assign b_rvalid = out_q && out_blk_q && dma_rvalid_i;
  assign r_rvalid = out_q && !out_blk_q && dma_rvalid_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_q <= 1'b0; out_blk_q <= 1'b0;
    end else if (dma_req_o && dma_gnt_i) begin
      out_q <= 1'b1; out_blk_q <= sel_blk;
    end else if (out_q && dma_rvalid_i) begin
      out_q <= 1'b0;
    end
  end

  // Simulation-only DMA trace, enabled by +g6lc_virtio_mmio_trace.
  // pragma translate_off
`ifndef SYNTHESIS
  bit trace_en;
  initial trace_en = $test$plusargs("g6lc_virtio_mmio_trace");
  always @(posedge clk_i) begin
    if (trace_en && rst_ni) begin
      if (dma_req_o && dma_gnt_i)
        $display("[virtio-dma] t=%0t %s a=%h d=%h be=%h src=%s", $time,
                 dma_we_o ? "W" : "R", dma_addr_o, dma_wdata_o, dma_be_o,
                 sel_blk ? "blk" : "ring");
      if (out_q && dma_rvalid_i)
        $display("[virtio-dma] t=%0t rsp d=%h err=%0d", $time, dma_rdata_i, dma_err_i);
    end
  end
`endif
  // pragma translate_on
endmodule
