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
  logic invalid_table;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dout <= 1'b0; sout <= 1'b0; init_p <= 1'b0; rpend_p <= 1'b0;
      base_p <= '0; size_p <= '0; status_wr_done <= 1'b0; status_inflight <= 1'b0;
      fl_seen <= 1'b0;
      invalid_table <= 1'b0;
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
      if (rs_valid || reset_pending_i) invalid_table <= 1'b0;
      if (req_valid_i && rq_ready) begin
        invalid_table <= req_nsegs_i < 2 || req_nsegs_i > 4;
        if (req_nsegs_i >= 2 && req_nsegs_i <= 4)
          invalid_table <= req_seg_len_i[req_nsegs_i - 1'b1] == 0;
      end
    end
  end

  logic [64:0] wend;
  assign wend = {1'b0, dma_base_i} + {1'b0, dma_size_i};
  logic [64:0] lemma_end, lemma_header, lemma_status;
  assign lemma_end = wend[64] ? {1'b1, 64'd0} : wend;
  assign lemma_header = {1'b0, dut.saddr_q[0][63:3], 3'b000};
  assign lemma_status = {1'b0, dut.saddr_q[dut.last][63:3], 3'b000};
  always_comb begin
    if (rst_ni) begin
      if (dma_rvalid_i) assume (dout);
      if (st_rvalid_i) assume (sout);
      if (st_flush_ack_i || st_flush_err_i) assume (flreq);
      if (init_p) assume (dma_base_i == base_p && dma_size_i == size_p);
      // Prove these invariants from reset and by unrestricted one-step
      // induction BEFORE using them in the pointwise window proof. They are
      // assertions here, not additional environmental assumptions. State
      // numbers follow the backend enum; a changed encoding must re-prove them.
      // STORAMIC_WINDOW_LEMMAS_BEGIN
      assert (!(dut.dpend_q && dut.dout_q));
      assert (!(dut.spend_q && dut.sout_q));
      if (dut.dpend_q)
        assert (dut.state_q inside {4'd1, 4'd5, 4'd6, 4'd8, 4'd10});
      if (dut.dout_q)
        assert (dut.state_q inside {4'd0, 4'd1, 4'd5, 4'd6, 4'd8, 4'd10});
      if (dut.spend_q)
        assert (dut.state_q inside {4'd4, 4'd7});
      if (dut.sout_q)
        assert (dut.state_q inside {4'd0, 4'd4, 4'd7});
      if (!(dut.state_q inside {4'd0, 4'd11, 4'd12})) begin
        assert (dut.nsegs_q >= 2 && dut.nsegs_q <= 4);
        assert (lemma_header >= {1'b0, dma_base_i} &&
                lemma_header + (65'(dut.hbeats_q) << 3) <= lemma_end);
        assert (lemma_status >= {1'b0, dma_base_i} && lemma_status + 65'd8 <= lemma_end);
      end
      if (dut.state_q == 4'd1) begin
        assert (dut.hbeats_q == ((dut.saddr_q[0][2:0] == 0) ? 2'd2 : 2'd3));
        assert (dut.hbeat_q < dut.hbeats_q);
        assert ({1'b0, daddr} == lemma_header + (65'(dut.hbeat_q) << 3));
      end
      if (dut.state_q inside {4'd4, 4'd5, 4'd6, 4'd7}) begin
        assert (dut.win_ok && dut.align_ok);
        assert (dut.seg_q >= 1 && dut.seg_q < dut.last);
        assert (dut.off_q < dut.slen_q[dut.seg_q] && dut.off_q[2:0] == 0);
      end
      if (dut.state_q inside {4'd5, 4'd6})
        assert ({1'b0, daddr} == {1'b0, dut.saddr_q[dut.seg_q]} + 65'(dut.off_q));
      if (dut.state_q == 4'd8) begin
        assert (dut.id_ok);
        assert (dut.off_q <= 16 && dut.off_q[2:0] == 0);
        assert ({1'b0, daddr} == {1'b0, dut.saddr_q[1]} + 65'(dut.off_q));
      end
      if (dut.state_q == 4'd10) assert ({1'b0, daddr} == lemma_status);
      // STORAMIC_WINDOW_LEMMAS_END
      // ---- safety ----
      if (dreq) begin
        assert (!dout);
        assert (daddr[2:0] == 3'b000);
        // STORAMIC_WINDOW_RANGE_BEGIN
        assert ({1'b0, daddr} >= {1'b0, dma_base_i} && {1'b0, daddr} + 65'd8 <= wend);
        // STORAMIC_WINDOW_RANGE_END
      end
      if (sreq) begin
        assert (!sout);
        // Observe the decoded header, but check the byte range independently
        // in 73 bits: a truncated sector or wrapped later beat lies outside it.
        assert ({9'd0, saddr} >= {dut.sector_q, 9'd0});
        assert ({9'd0, saddr} + 73'd8 <=
                {dut.sector_q, 9'd0} + 73'(dut.total_q));
        assert ({dut.sector_q, 9'd0} + 73'(dut.total_q) <= (73'd1 << 64));
      end
      if (invalid_table) assert (!dreq && !sreq && !flreq);
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
