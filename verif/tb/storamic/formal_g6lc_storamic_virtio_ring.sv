// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-035 formal wrapper. Memory responses, grants, the backend and the
// transport are free inputs, constrained only by protocol:
// - rvalid only while a granted beat is outstanding;
// - queue geometry, window and driver_ok/queue_ready change only while
//   reset_pending is high, and the epoch changes only right after it;
// - queue_num is a power of two no larger than QueueNumMax.
// Shadow registers replace $past (not supported by the toolchain frontend).
module formal_g6lc_storamic_virtio_ring (
  input logic clk_i,
  input logic rst_ni,
  input logic queue_ready_i,
  input logic [15:0] queue_num_i,
  input logic [63:0] queue_desc_i,
  input logic [63:0] queue_driver_i,
  input logic [63:0] queue_device_i,
  input logic driver_ok_i,
  input logic notify_i,
  input logic reset_pending_i,
  input logic [7:0] reset_epoch_i,
  input logic [63:0] dma_base_i,
  input logic [63:0] dma_size_i,
  input logic dma_gnt_i,
  input logic dma_rvalid_i,
  input logic [63:0] dma_rdata_i,
  input logic dma_err_i,
  input logic req_ready_i,
  input logic rsp_valid_i,
  input logic [31:0] rsp_written_len_i,
  input logic rsp_fault_i,
  output logic cover_done_o,
  output logic cover_fault_o,
  output logic cover_reset_walk_o
);
  localparam int unsigned MaxSegs = 2;
  logic idle, used_ev, fault, dreq, dwe, bvalid;
  logic [63:0] daddr, dwdata;
  logic [7:0] dbe;

  g6lc_storamic_virtio_ring #(.MaxSegs(MaxSegs), .QueueNumMax(4)) dut (
    .clk_i, .rst_ni, .queue_ready_i, .queue_num_i, .queue_desc_i,
    .queue_driver_i, .queue_device_i, .driver_ok_i, .notify_i,
    .reset_pending_i, .reset_epoch_i,
    .dma_idle_o(idle), .used_event_o(used_ev), .ring_fault_o(fault),
    .dma_base_i, .dma_size_i,
    .dma_req_o(dreq), .dma_gnt_i, .dma_we_o(dwe), .dma_addr_o(daddr),
    .dma_wdata_o(dwdata), .dma_be_o(dbe), .dma_rvalid_i, .dma_rdata_i,
    .dma_err_i,
    .req_valid_o(bvalid), .req_ready_i, .req_head_o(), .req_nsegs_o(),
    .req_seg_addr_o(), .req_seg_len_o(), .req_seg_write_o(),
    .rsp_valid_i, .rsp_written_len_i, .rsp_fault_i
  );

  // Outstanding-beat tracker (independent of the DUT).
  logic outst, outst_we;
  logic [63:0] outst_addr;
  logic [7:0] outst_be;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      outst <= 1'b0; outst_we <= 1'b0; outst_addr <= '0; outst_be <= '0;
    end else begin
      if (dreq && dma_gnt_i) begin
        outst <= 1'b1; outst_we <= dwe; outst_addr <= daddr; outst_be <= dbe;
      end else if (dma_rvalid_i) outst <= 1'b0;
    end
  end

  // Shadows for protocol assumptions.
  logic rpend_p, active_p, dreq_p, init_p;
  logic [15:0] qnum_p;
  logic [63:0] qdesc_p, qdrv_p, qdev_p, base_p, size_p;
  logic dok_p, qready_p;
  logic [7:0] epoch_p;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      init_p <= 1'b0; rpend_p <= 1'b0; active_p <= 1'b0; dreq_p <= 1'b0;
      qnum_p <= '0; qdesc_p <= '0; qdrv_p <= '0; qdev_p <= '0;
      base_p <= '0; size_p <= '0; dok_p <= 1'b0; qready_p <= 1'b0;
      epoch_p <= '0;
    end else begin
      init_p <= 1'b1;
      rpend_p <= reset_pending_i;
      active_p <= driver_ok_i && queue_ready_i && !reset_pending_i;
      dreq_p <= dreq;
      qnum_p <= queue_num_i; qdesc_p <= queue_desc_i; qdrv_p <= queue_driver_i;
      qdev_p <= queue_device_i; base_p <= dma_base_i; size_p <= dma_size_i;
      dok_p <= driver_ok_i; qready_p <= queue_ready_i; epoch_p <= reset_epoch_i;
    end
  end

  // Used-ring publication tracking from the DMA trace.
  logic elem_done, idx_done;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      elem_done <= 1'b0; idx_done <= 1'b0;
    end else begin
      if (dma_rvalid_i && outst && outst_we && !dma_err_i) begin
        if (outst_be == 8'h03 || outst_be == 8'h0C || outst_be == 8'h30 ||
            outst_be == 8'hC0)
          idx_done <= 1'b1;
        else elem_done <= 1'b1;
      end
      if (used_ev || reset_pending_i) begin
        elem_done <= 1'b0; idx_done <= 1'b0;
      end
    end
  end

  logic [64:0] wend;
  assign wend = {1'b0, dma_base_i} + {1'b0, dma_size_i};

  // Immediate checks on the current step against previous-step shadows.
  always_comb begin
    if (rst_ni) begin
      // ---- assumptions ----
      assume (queue_num_i == 16'd1 || queue_num_i == 16'd2 || queue_num_i == 16'd4);
      // ST-034 only sets QueueReady for these alignments.
      assume (queue_desc_i[3:0] == 4'h0 && queue_driver_i[0] == 1'b0 &&
              queue_device_i[1:0] == 2'b00);
      if (dma_rvalid_i) assume (outst);
      if (init_p && !rpend_p) begin
        assume (queue_num_i == qnum_p && queue_desc_i == qdesc_p &&
                queue_driver_i == qdrv_p && queue_device_i == qdev_p &&
                dma_base_i == base_p && dma_size_i == size_p &&
                driver_ok_i == dok_p && queue_ready_i == qready_p);
        assume (reset_epoch_i == epoch_p);
      end
      // ---- safety ----
      if (dreq) begin
        assert (daddr[2:0] == 3'b000);
        assert ({1'b0, daddr} >= {1'b0, dma_base_i} && {1'b0, daddr} + 65'd8 <= wend);
        assert (!outst);                       // one outstanding beat
      end
      if (dreq && !dreq_p) assert (active_p);  // decided while active
      if (used_ev) assert (idx_done && elem_done);
      if (dreq && dwe && (dbe == 8'h03 || dbe == 8'h0C || dbe == 8'h30 ||
                          dbe == 8'hC0))
        assert (elem_done);
      assert (dut.count_q <= 16'd4);
      if (idle) assert (!dreq && !outst);
      if (dut.state_q == 4'd10) assert (!dreq);  // SDead issues nothing
    end
  end

  logic cov_done, cov_fault, cov_rw;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cov_done <= 1'b0; cov_fault <= 1'b0; cov_rw <= 1'b0;
    end else begin
      if (used_ev) cov_done <= 1'b1;
      if (fault) cov_fault <= 1'b1;
      if (reset_pending_i && (dut.state_q == 4'd3 || dut.state_q == 4'd4))
        cov_rw <= 1'b1;
    end
  end
  assign cover_done_o = cov_done;
  assign cover_fault_o = cov_fault;
  assign cover_reset_walk_o = cov_rw;
endmodule
