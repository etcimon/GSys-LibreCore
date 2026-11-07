// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-036 formal wrapper. Ring requests, DMA and store responses are free,
// constrained only by protocol (responses only while a beat is outstanding,
// request fields stable while req_valid, window stable). Immediate checks on
// the current step against previous-step shadows.
module formal_g6lc_storamic_virtio_blk #(
  // ST-037D: 1 binds a free flush-response environment and enables the flush
  // safety/coverage properties below.
  parameter bit FlushEn = 1'b0
) (
  input logic clk_i,
  input logic rst_ni,
  input logic reset_pending_i,
  input logic req_valid_i,
  input logic [2:0] req_nsegs_i,
  input logic [3:0][63:0] req_seg_addr_i,
  input logic [3:0][31:0] req_seg_len_i,
  input logic [3:0] req_seg_write_i,
  input logic [63:0] dma_base_i,
  input logic [63:0] dma_size_i,
  input logic dma_gnt_i,
  input logic dma_rvalid_i,
  input logic [63:0] dma_rdata_i,
  input logic dma_err_i,
  input logic store_ready_i,
  input logic [63:0] capacity_i,
  input logic st_gnt_i,
  input logic st_rvalid_i,
  input logic [63:0] st_rdata_i,
  input logic st_err_i,
  input logic st_flush_ack_i,
  input logic st_flush_err_i,
  output logic cover_rsp_o,
  output logic cover_status_o,
  output logic cover_flush_o
);
  logic idle, rq_ready, rs_valid, rs_fault, dreq, dwe, sreq, swe;
  logic [31:0] rs_len;
  logic [63:0] daddr, dwdata, saddr, swdata;
  logic [7:0] dbe, sbe;

  logic flreq;
  g6lc_storamic_virtio_blk #(.MaxSegs(4)) dut (
    .clk_i, .rst_ni, .reset_pending_i, .idle_o(idle),
    .job_idle_o(),
    .req_valid_i, .req_ready_o(rq_ready), .req_nsegs_i, .req_seg_addr_i,
    .req_seg_len_i, .req_seg_write_i,
    .rsp_valid_o(rs_valid), .rsp_written_len_o(rs_len), .rsp_fault_o(rs_fault),
    .dma_base_i, .dma_size_i,
    .dma_req_o(dreq), .dma_gnt_i, .dma_we_o(dwe), .dma_addr_o(daddr),
    .dma_wdata_o(dwdata), .dma_be_o(dbe), .dma_rvalid_i, .dma_rdata_i, .dma_err_i,
    .store_ready_i, .capacity_i, .serial_i('0),
    .st_req_o(sreq), .st_gnt_i, .st_we_o(swe), .st_addr_o(saddr),
    .st_wdata_o(swdata), .st_be_o(sbe), .st_rvalid_i, .st_rdata_i, .st_err_i,
    .flush_en_i(FlushEn), .st_flush_req_o(flreq),
    .st_flush_ack_i(st_flush_ack_i), .st_flush_err_i(st_flush_err_i)
  );

  logic dout, sout, init_p, rpend_p;
  logic cov_flush, fl_seen;
  logic [63:0] base_p, size_p;
  logic status_wr_done;   // the status byte write of the current request returned
  logic status_inflight;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dout <= 1'b0; sout <= 1'b0; init_p <= 1'b0; rpend_p <= 1'b0;
      base_p <= '0; size_p <= '0; status_wr_done <= 1'b0; status_inflight <= 1'b0;
      fl_seen <= 1'b0;
    end else begin
      init_p <= 1'b1; rpend_p <= reset_pending_i;
      base_p <= dma_base_i; size_p <= dma_size_i;
      if (flreq && (st_flush_ack_i || st_flush_err_i)) fl_seen <= 1'b1;
      if (rs_valid) fl_seen <= 1'b0;
      if (dreq && dma_gnt_i) begin
        dout <= 1'b1;
        // The status byte is the write granted while the backend is in SRsp.
        status_inflight <= dwe && dut.state_q == 4'd10;
      end else if (dma_rvalid_i) dout <= 1'b0;
      // A grant abandoned by reset_pending must not credit status_wr_done
      // when its response returns later (depth-14 counterexample: fault
      // response with a stale status_wr_done).
      if (reset_pending_i) status_inflight <= 1'b0;
      if (sreq && st_gnt_i) sout <= 1'b1;
      else if (st_rvalid_i) sout <= 1'b0;
      if (dma_rvalid_i && dout && status_inflight && !dma_err_i) status_wr_done <= 1'b1;
      if (rs_valid || reset_pending_i) status_wr_done <= 1'b0;
    end
  end

  logic [64:0] wend;
  assign wend = {1'b0, dma_base_i} + {1'b0, dma_size_i};
  always_comb begin
    if (rst_ni) begin
      if (dma_rvalid_i) assume (dout);
      if (st_rvalid_i) assume (sout);
      if (st_flush_ack_i || st_flush_err_i) assume (flreq);
      if (init_p) assume (dma_base_i == base_p && dma_size_i == size_p);
      // ---- safety ----
      if (dreq) begin
        assert (!dout);
        assert (daddr[2:0] == 3'b000);
        assert ({1'b0, daddr} >= {1'b0, dma_base_i} && {1'b0, daddr} + 65'd8 <= wend);
      end
      if (sreq) assert (!sout);
      // No new DMA or store beat may be requested while a flush is
      // outstanding (accept is blocked by idle_o and SFlush issues none).
      // dout/sout from a beat abandoned across reset_pending can legally
      // linger, so they are not part of this property.
      if (flreq) assert (!dreq && !sreq);
      if (rs_valid && !rs_fault) assert (status_wr_done);
      if (rs_valid && rs_fault) assert (!status_wr_done);
      if (idle) assert (!dreq && !sreq && !dout && !sout);
    end
  end

  logic cov_rsp, cov_status;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin cov_rsp <= 1'b0; cov_status <= 1'b0; end
    else begin
      if (rs_valid && !rs_fault) cov_rsp <= 1'b1;
      if (status_wr_done) cov_status <= 1'b1;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) cov_flush <= 1'b0;
    else if (status_wr_done && fl_seen) cov_flush <= 1'b1;
  end
  assign cover_rsp_o = cov_rsp;
  assign cover_status_o = cov_status;
  assign cover_flush_o = cov_flush;
endmodule

// ST-037D flush variant: FlushEn=1, free flush ack/err environment.
module formal_g6lc_storamic_virtio_blk_flush (
  input logic clk_i, input logic rst_ni, input logic reset_pending_i,
  input logic req_valid_i, input logic [2:0] req_nsegs_i,
  input logic [3:0][63:0] req_seg_addr_i,
  input logic [3:0][31:0] req_seg_len_i, input logic [3:0] req_seg_write_i,
  input logic [63:0] dma_base_i, input logic [63:0] dma_size_i,
  input logic dma_gnt_i, input logic dma_rvalid_i,
  input logic [63:0] dma_rdata_i, input logic dma_err_i,
  input logic store_ready_i, input logic [63:0] capacity_i,
  input logic st_gnt_i, input logic st_rvalid_i,
  input logic [63:0] st_rdata_i, input logic st_err_i,
  input logic st_flush_ack_i, input logic st_flush_err_i,
  output logic cover_rsp_o, output logic cover_status_o,
  output logic cover_flush_o
);
  formal_g6lc_storamic_virtio_blk #(.FlushEn(1'b1)) w (.*);
endmodule
