// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// ST-035 split-ring engine for queue 0 of one ST-034 transport (contract:
// architecture/virtio-mmio.md "Split-ring engine contract"). One request in
// flight, one DMA beat outstanding, no INDIRECT/EVENT_IDX/packed/IN_ORDER.
//
// DMA seam: single 64-bit beats, 8-byte aligned. A presented request is held
// until dma_gnt_i, except that reset_pending_i withdraws an ungranted request.
// Every granted request (read or write) returns exactly one dma_rvalid_i.
// The window check is beat-granular: the whole aligned beat must lie inside
// [dma_base_i, dma_base_i + dma_size_i), which is stricter than the field.
// Segments handed to the backend are checked over [addr, addr + len).
//
// Timing: the window comparators are 65-bit add/compare on the issue path;
// the request is registered, so they do not reach dma_req_o combinationally.
module g6lc_storamic_virtio_ring #(
  parameter int unsigned MaxSegs = 8,
  parameter int unsigned QueueNumMax = 128,
  localparam int unsigned SegW = $clog2(MaxSegs + 1)
) (
  input logic clk_i,
  input logic rst_ni,
  // transport
  input logic queue_ready_i,
  input logic [15:0] queue_num_i,
  input logic [63:0] queue_desc_i,
  input logic [63:0] queue_driver_i,
  input logic [63:0] queue_device_i,
  input logic driver_ok_i,
  input logic notify_i,
  input logic reset_pending_i,
  input logic [7:0] reset_epoch_i,
  output logic dma_idle_o,
  output logic used_event_o,
  output logic ring_fault_o,
  // DMA window
  input logic [63:0] dma_base_i,
  input logic [63:0] dma_size_i,
  // DMA port
  output logic dma_req_o,
  input logic dma_gnt_i,
  output logic dma_we_o,
  output logic [63:0] dma_addr_o,
  output logic [63:0] dma_wdata_o,
  output logic [7:0] dma_be_o,
  input logic dma_rvalid_i,
  input logic [63:0] dma_rdata_i,
  input logic dma_err_i,
  // backend
  output logic req_valid_o,
  input logic req_ready_i,
  output logic [15:0] req_head_o,
  output logic [SegW-1:0] req_nsegs_o,
  output logic [MaxSegs-1:0][63:0] req_seg_addr_o,
  output logic [MaxSegs-1:0][31:0] req_seg_len_o,
  output logic [MaxSegs-1:0] req_seg_write_o,
  input logic rsp_valid_i,
  input logic [31:0] rsp_written_len_i,
  input logic rsp_fault_i
);
  if (MaxSegs < 2 || QueueNumMax < 1 || QueueNumMax > 32768 ||
      (QueueNumMax & (QueueNumMax - 1)) != 0) begin : gen_param_guard
    // pragma translate_off
    initial $fatal(1, "STORAMIC_VIRTIO_RING_PARAM");
    // pragma translate_on
  end

  typedef enum logic [3:0] {
    SIdle, SAvailIdx, SHead, SDescA, SDescB, SHandoff, SWaitRsp,
    SUsedLo, SUsedHi, SUsedIdx, SDead
  } state_t;

  localparam logic [15:0] FNext = 16'h1, FWrite = 16'h2, FIndirect = 16'h4;

  state_t state_q;
  logic pend_q, out_q;            // request presented / granted, awaiting rvalid
  logic we_q;
  logic [63:0] addr_q, wdata_q;
  logic [7:0] be_q;
  logic [1:0] shift_q;            // 16-bit lane of the field being read
  logic notify_pend_q;
  logic [7:0] epoch_q;
  logic [15:0] last_avail_q, used_idx_q, head_q, desc_i_q, count_q;
  logic [63:0] daddr_q;
  logic [SegW-1:0] nseg_q;
  logic seen_write_q;
  logic [MaxSegs-1:0][63:0] seg_addr_q;
  logic [MaxSegs-1:0][31:0] seg_len_q;
  logic [MaxSegs-1:0] seg_wr_q;
  logic [31:0] wlen_q;
  logic used_event_q, fault_q;

  logic active;
  assign active = driver_ok_i && queue_ready_i && !reset_pending_i;
  logic [15:0] qmask;
  assign qmask = queue_num_i - 16'd1;   // queue_num is a power of two (ST-034)

  // Window check helpers (65-bit).
  logic [64:0] win_end;
  assign win_end = {1'b0, dma_base_i} + {1'b0, dma_size_i};
  function automatic logic in_window(input logic [63:0] a, input logic [64:0] n,
                                     input logic [63:0] base, input logic [64:0] wend);
    logic [64:0] e;
    e = {1'b0, a} + n;
    return ({1'b0, a} >= {1'b0, base}) && (e <= wend);
  endfunction
  function automatic logic [15:0] field16(input logic [63:0] d, input logic [1:0] s);
    return d[16*s +: 16];
  endfunction

  // Addresses of the ring fields for the current indices.
  logic [63:0] avail_idx_a, avail_ring_a, used_elem_a, used_idx_a;
  assign avail_idx_a = queue_driver_i + 64'd2;
  assign avail_ring_a = queue_driver_i + 64'd4 + {47'h0, last_avail_q & qmask, 1'b0};
  assign used_elem_a = queue_device_i + 64'd4 + {45'h0, used_idx_q & qmask, 3'b000};
  assign used_idx_a = queue_device_i + 64'd2;

  // Descriptor fields of the beat-B response.
  logic [31:0] d_len;
  logic [15:0] d_flags, d_next;
  assign d_len = dma_rdata_i[31:0];
  assign d_flags = dma_rdata_i[47:32];
  assign d_next = dma_rdata_i[63:48];

  assign dma_req_o = pend_q;
  assign dma_we_o = we_q;
  assign dma_addr_o = addr_q;
  assign dma_wdata_o = wdata_q;
  assign dma_be_o = be_q;
  assign dma_idle_o = !pend_q && !out_q;
  assign used_event_o = used_event_q;
  assign ring_fault_o = fault_q;
  assign req_valid_o = (state_q == SHandoff) && !reset_pending_i;
  assign req_head_o = head_q;
  assign req_nsegs_o = nseg_q;
  assign req_seg_addr_o = seg_addr_q;
  assign req_seg_len_o = seg_len_q;
  assign req_seg_write_o = seg_wr_q;

  logic rsp_beat;
  assign rsp_beat = out_q && dma_rvalid_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= SIdle;
      pend_q <= 1'b0; out_q <= 1'b0; we_q <= 1'b0;
      addr_q <= '0; wdata_q <= '0; be_q <= '0; shift_q <= '0;
      notify_pend_q <= 1'b0; epoch_q <= '0;
      last_avail_q <= '0; used_idx_q <= '0; head_q <= '0; desc_i_q <= '0;
      count_q <= '0; daddr_q <= '0; nseg_q <= '0; seen_write_q <= 1'b0;
      seg_addr_q <= '0; seg_len_q <= '0; seg_wr_q <= '0; wlen_q <= '0;
      used_event_q <= 1'b0; fault_q <= 1'b0;
    end else begin
      used_event_q <= 1'b0;
      fault_q <= 1'b0;
      if (notify_i) notify_pend_q <= 1'b1;
      if (pend_q && dma_gnt_i) begin
        pend_q <= 1'b0;
        out_q <= 1'b1;
      end
      if (rsp_beat) out_q <= 1'b0;

      if (reset_pending_i) begin
        // Quiesce: withdraw an ungranted request, let the outstanding beat
        // return, abandon the request in progress.
        if (!(pend_q && dma_gnt_i)) pend_q <= 1'b0;
        if (state_q != SDead) state_q <= SIdle;
      end else if (reset_epoch_i != epoch_q) begin
        // Reset completed: indices restart; a dead engine is revived.
        epoch_q <= reset_epoch_i;
        last_avail_q <= '0; used_idx_q <= '0;
        notify_pend_q <= notify_i;
        state_q <= SIdle;
      end else begin
        unique case (state_q)
          SIdle: begin
            if (active && (notify_pend_q || notify_i) && !out_q) begin
              notify_pend_q <= 1'b0;
              if (!in_window(avail_idx_a & ~64'h7, 65'd8, dma_base_i, win_end)) begin
                fault_q <= 1'b1; state_q <= SDead;
              end else begin
                pend_q <= 1'b1; we_q <= 1'b0; be_q <= '0; wdata_q <= '0;
                addr_q <= avail_idx_a & ~64'h7; shift_q <= avail_idx_a[2:1];
                state_q <= SAvailIdx;
              end
            end
          end
          SAvailIdx: if (rsp_beat) begin
            if (dma_err_i) begin
              fault_q <= 1'b1; state_q <= SDead;
            end else if (field16(dma_rdata_i, shift_q) == last_avail_q) begin
              state_q <= SIdle;
            end else if (!in_window(avail_ring_a & ~64'h7, 65'd8, dma_base_i, win_end)) begin
              fault_q <= 1'b1; state_q <= SDead;
            end else begin
              pend_q <= 1'b1; addr_q <= avail_ring_a & ~64'h7;
              shift_q <= avail_ring_a[2:1];
              state_q <= SHead;
            end
          end
          SHead: if (rsp_beat) begin
            if (dma_err_i || field16(dma_rdata_i, shift_q) >= queue_num_i ||
                !in_window(queue_desc_i + {44'h0, field16(dma_rdata_i, shift_q), 4'h0},
                           65'd16, dma_base_i, win_end)) begin
              fault_q <= 1'b1; state_q <= SDead;
            end else begin
              head_q <= field16(dma_rdata_i, shift_q);
              desc_i_q <= field16(dma_rdata_i, shift_q);
              count_q <= 16'd1; nseg_q <= '0; seen_write_q <= 1'b0;
              pend_q <= 1'b1;
              addr_q <= queue_desc_i + {44'h0, field16(dma_rdata_i, shift_q), 4'h0};
              state_q <= SDescA;
            end
          end
          SDescA: if (rsp_beat) begin
            if (dma_err_i) begin
              fault_q <= 1'b1; state_q <= SDead;
            end else begin
              daddr_q <= dma_rdata_i;
              pend_q <= 1'b1; addr_q <= addr_q + 64'd8;
              state_q <= SDescB;
            end
          end
          SDescB: if (rsp_beat) begin
            if (dma_err_i || (d_flags & FIndirect) != 0 || d_len == 0 ||
                ((d_flags & FWrite) == 0 && seen_write_q) ||
                int'(nseg_q) >= int'(MaxSegs) ||
                !in_window(daddr_q, {33'h0, d_len}, dma_base_i, win_end)) begin
              fault_q <= 1'b1; state_q <= SDead;
            end else begin
              seg_addr_q[nseg_q] <= daddr_q;
              seg_len_q[nseg_q] <= d_len;
              seg_wr_q[nseg_q] <= (d_flags & FWrite) != 0;
              nseg_q <= nseg_q + 1'b1;
              if ((d_flags & FWrite) != 0) seen_write_q <= 1'b1;
              if ((d_flags & FNext) == 0) begin
                state_q <= SHandoff;
              end else if (d_next >= queue_num_i || count_q >= queue_num_i ||
                           !in_window(queue_desc_i + {44'h0, d_next, 4'h0}, 65'd16,
                                      dma_base_i, win_end)) begin
                fault_q <= 1'b1; state_q <= SDead;
              end else begin
                desc_i_q <= d_next; count_q <= count_q + 16'd1;
                pend_q <= 1'b1; addr_q <= queue_desc_i + {44'h0, d_next, 4'h0};
                state_q <= SDescA;
              end
            end
          end
          SHandoff: if (req_ready_i) state_q <= SWaitRsp;
          SWaitRsp: if (rsp_valid_i) begin
            if (rsp_fault_i ||
                !in_window(used_elem_a & ~64'h7, used_elem_a[2] ? 65'd16 : 65'd8,
                           dma_base_i, win_end) ||
                !in_window(used_idx_a & ~64'h7, 65'd8, dma_base_i, win_end)) begin
              fault_q <= 1'b1; state_q <= SDead;
            end else begin
              wlen_q <= rsp_written_len_i;
              pend_q <= 1'b1; we_q <= 1'b1;
              addr_q <= used_elem_a & ~64'h7;
              if (used_elem_a[2]) begin
                // Element straddles two beats: id in the upper half here.
                be_q <= 8'hF0; wdata_q <= {16'h0, head_q, 32'h0};
              end else begin
                be_q <= 8'hFF; wdata_q <= {rsp_written_len_i, 16'h0, head_q};
              end
              state_q <= SUsedLo;
            end
          end
          SUsedLo: if (rsp_beat) begin
            if (dma_err_i) begin
              fault_q <= 1'b1; state_q <= SDead;
            end else if (used_elem_a[2]) begin
              pend_q <= 1'b1; addr_q <= addr_q + 64'd8;
              be_q <= 8'h0F; wdata_q <= {32'h0, wlen_q};
              state_q <= SUsedHi;
            end else begin
              pend_q <= 1'b1; addr_q <= used_idx_a & ~64'h7;
              be_q <= 8'b11 << (2 * used_idx_a[2:1]);
              wdata_q <= {48'h0, used_idx_q + 16'd1} << (16 * used_idx_a[2:1]);
              state_q <= SUsedIdx;
            end
          end
          SUsedHi: if (rsp_beat) begin
            if (dma_err_i) begin
              fault_q <= 1'b1; state_q <= SDead;
            end else begin
              pend_q <= 1'b1; addr_q <= used_idx_a & ~64'h7;
              be_q <= 8'b11 << (2 * used_idx_a[2:1]);
              wdata_q <= {48'h0, used_idx_q + 16'd1} << (16 * used_idx_a[2:1]);
              state_q <= SUsedIdx;
            end
          end
          SUsedIdx: if (rsp_beat) begin
            if (dma_err_i) begin
              fault_q <= 1'b1; state_q <= SDead;
            end else begin
              used_event_q <= 1'b1;
              last_avail_q <= last_avail_q + 16'd1;
              used_idx_q <= used_idx_q + 16'd1;
              we_q <= 1'b0; be_q <= '0; wdata_q <= '0;
              // Re-read avail.idx: catches requests posted without a notify.
              pend_q <= 1'b1; addr_q <= avail_idx_a & ~64'h7;
              shift_q <= avail_idx_a[2:1];
              state_q <= SAvailIdx;
            end
          end
          SDead: ;
          default: state_q <= SIdle;
        endcase
      end
    end
  end
endmodule
